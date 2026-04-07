import Foundation

/// すべてのコンポーネントを統合するファサード。
/// すべてのピアは対等であり、コーディネーターは内部で自動選出される。
public final class PeerClock: @unchecked Sendable {

    // MARK: - Public Static

    public static let version = "0.2.0"

    // MARK: - Public Properties

    /// このインスタンスのローカルピアID（init 時に生成される）
    public let localPeerID: PeerID

    // MARK: - Public Streams

    /// 同期状態の変化を流すストリーム
    public let syncState: AsyncStream<SyncState>

    /// 既知ピアリストの変化を流すストリーム
    public let peers: AsyncStream<[Peer]>

    /// 受信したアプリケーションコマンドを流すストリーム
    public var commands: AsyncStream<(PeerID, Command)> {
        commandRouter?.incomingCommands ?? AsyncStream { $0.finish() }
    }

    // MARK: - Computed

    /// 同期オフセットを適用した現在時刻（ナノ秒）
    public var now: UInt64 {
        let machNow = NTPSyncEngine.now()
        let offsetNs = Int64((syncEngine?.currentOffset ?? 0.0) * 1_000_000_000)
        return UInt64(Int64(machNow) + offsetNs)
    }

    /// 現在選出されている sync coordinator の PeerID。未選出時は nil。
    /// デバッグ・可視化用途。通常のアプリロジックはこの値を気にする必要はない。
    public var coordinatorID: PeerID? {
        lock.withLock { currentCoordinator }
    }

    // MARK: - Private: Configuration

    private let configuration: Configuration
    private let transportFactory: @Sendable (PeerID) -> any Transport

    // MARK: - Private: Components

    private let lock = NSLock()
    private var transport: (any Transport)?
    private var election: CoordinatorElection?
    private var syncEngine: NTPSyncEngine?
    private var driftMonitor: DriftMonitor?
    private var commandRouter: CommandRouter?

    // MARK: - Private: Tasks

    private var coordinationTask: Task<Void, Never>?
    private var syncResponderTask: Task<Void, Never>?
    private var syncStateForwardTask: Task<Void, Never>?

    // MARK: - Private: Stream Continuations

    private let syncStateContinuation: AsyncStream<SyncState>.Continuation
    private let peersContinuation: AsyncStream<[Peer]>.Continuation

    // MARK: - Private: State

    private var knownPeers: Set<PeerID> = []
    private var currentCoordinator: PeerID?

    // MARK: - Init

    public init(
        configuration: Configuration = .default,
        transportFactory: (@Sendable (PeerID) -> any Transport)? = nil
    ) {
        self.localPeerID = PeerID(UUID())
        self.configuration = configuration
        self.transportFactory = transportFactory ?? { peerID in
            WiFiTransport(localPeerID: peerID, configuration: configuration)
        }

        var syncStateCont: AsyncStream<SyncState>.Continuation!
        var peersCont: AsyncStream<[Peer]>.Continuation!

        self.syncState = AsyncStream { syncStateCont = $0 }
        self.peers = AsyncStream { peersCont = $0 }

        self.syncStateContinuation = syncStateCont
        self.peersContinuation = peersCont
    }

    // MARK: - Public API

    /// ピア探索と同期を開始する
    public func start() async throws {
        let tr: any Transport = lock.withLock {
            let newTransport = transportFactory(localPeerID)
            self.transport = newTransport

            let elec = CoordinatorElection(localPeerID: localPeerID)
            self.election = elec

            let router = CommandRouter(transport: newTransport)
            self.commandRouter = router

            let eng = NTPSyncEngine(
                transport: newTransport,
                configuration: configuration,
                syncMessageStream: router.syncMessages
            )
            self.syncEngine = eng

            let dm = DriftMonitor()
            self.driftMonitor = dm

            // 自分自身は最初から既知ピアに含める
            knownPeers = [localPeerID]

            return newTransport
        }

        try tr.start()

        syncStateContinuation.yield(.discovering)

        // syncEngine のステート更新を転送するタスク
        let eng = lock.withLock { syncEngine! }
        let dm = lock.withLock { driftMonitor! }
        let cont = syncStateContinuation
        let forwardTask = Task {
            for await state in eng.syncStateUpdates {
                cont.yield(state)
                if case .synced(let offset, _) = state {
                    dm.recordOffset(offset * 1_000_000_000)
                }
            }
        }
        lock.withLock { self.syncStateForwardTask = forwardTask }

        // メイン協調タスクを開始
        let coordTask = Task { [weak self] in
            guard let self else { return }
            await self.runCoordinationLoop(transport: tr)
        }
        lock.withLock { self.coordinationTask = coordTask }
    }

    /// 同期を停止する
    public func stop() async {
        let (coordTask, syncResponder, fwdTask, eng, tr) = lock.withLock {
            let c = coordinationTask
            coordinationTask = nil
            let s = syncResponderTask
            syncResponderTask = nil
            let f = syncStateForwardTask
            syncStateForwardTask = nil
            let e = syncEngine
            let t = transport
            return (c, s, f, e, t)
        }

        coordTask?.cancel()
        syncResponder?.cancel()
        fwdTask?.cancel()

        await coordTask?.value
        await syncResponder?.value
        await fwdTask?.value

        await eng?.stop()
        tr?.stop()

        syncStateContinuation.yield(.idle)
    }

    /// 指定ピアにコマンドを送信する
    public func send(_ command: Command, to peer: PeerID) async throws {
        guard let router = lock.withLock({ commandRouter }) else { return }
        try await router.send(command, to: peer)
    }

    /// 全ピアにコマンドをブロードキャストする
    public func broadcast(_ command: Command) async throws {
        guard let router = lock.withLock({ commandRouter }) else { return }
        try await router.broadcast(command)
    }

    // MARK: - Private: Coordination Loop

    private func runCoordinationLoop(transport: any Transport) async {
        for await event in transport.connectionEvents {
            guard !Task.isCancelled else { break }

            let (newPeerList, elec, eng) = lock.withLock { () -> ([PeerID], CoordinatorElection?, NTPSyncEngine?) in
                switch event {
                case .peerJoined(let peerID):
                    knownPeers.insert(peerID)
                case .peerLeft(let peerID):
                    knownPeers.remove(peerID)
                case .transportDegraded, .transportRestored:
                    break
                }
                return (Array(knownPeers), election, syncEngine)
            }

            guard let elec, let eng else { continue }

            // ピアリストをストリームに流す
            let peerList = newPeerList.map { peerID in
                Peer(
                    id: peerID,
                    name: peerID.description,
                    status: PeerStatus(
                        peerID: peerID,
                        connectionState: .connected,
                        deviceInfo: DeviceInfo(
                            name: peerID.description,
                            platform: .iOS,
                            storageAvailable: 0
                        ),
                        generation: 0
                    )
                )
            }
            peersContinuation.yield(peerList)

            // コーディネーター選出を更新
            elec.updatePeers(newPeerList)
            let coordinator = elec.coordinator
            let isCoord = elec.isCoordinator

            let prevCoordinator = lock.withLock { () -> PeerID? in
                let prev = currentCoordinator
                currentCoordinator = coordinator
                return prev
            }

            // コーディネーターが変わった場合のみ処理
            guard coordinator != prevCoordinator else { continue }

            if isCoord {
                // 自分がコーディネーター: 同期エンジンを停止し、レスポンダーを起動
                await eng.stop()
                startSyncResponder(transport: transport)
            } else if let coordinator {
                // 自分はフォロワー: レスポンダーを停止し、同期エンジンを起動
                lock.withLock { () -> Task<Void, Never>? in
                    let t = syncResponderTask
                    syncResponderTask = nil
                    return t
                }?.cancel()

                await eng.stop()
                await eng.start(coordinator: coordinator)
            }
        }
    }

    // MARK: - Private: Sync Responder

    /// SYNC_REQUEST に対して SYNC_RESPONSE を返すタスクを開始する
    private func startSyncResponder(transport: any Transport) {
        let existing = lock.withLock { () -> Task<Void, Never>? in
            let old = syncResponderTask
            syncResponderTask = nil
            return old
        }
        existing?.cancel()

        let syncStream = lock.withLock { commandRouter?.syncMessages }
        guard let syncStream else { return }
        let task = Task { [weak self] in
            guard self != nil else { return }
            for await (sender, data) in syncStream {
                guard !Task.isCancelled else { break }
                guard let message = try? MessageCodec.decode(data),
                      message.category == .syncRequest,
                      let t0 = try? MessageCodec.decodeSyncRequest(message.payload)
                else { continue }

                let t1 = NTPSyncEngine.now()
                let t2 = NTPSyncEngine.now()
                let responsePayload = MessageCodec.encodeSyncResponse(t0: t0, t1: t1, t2: t2)
                let response = WireMessage(category: .syncResponse, payload: responsePayload)
                let responseData = MessageCodec.encode(response)
                try? await transport.sendReliable(responseData, to: sender)
            }
        }

        lock.withLock { syncResponderTask = task }
    }
}
