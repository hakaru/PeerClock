import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    /// 現在の同期状態のアトミックスナップショット。
    /// schedule のガードや UI 表示で使用する。
    public var currentSync: SyncSnapshot {
        let captured = NTPSyncEngine.now()
        return lock.withLock {
            // コーディネーター自身は時刻基準なので常に synced 扱い
            // (eng.start() が呼ばれないため lastSyncState は .idle のままになる)
            let isCoordinatorSelf = (self.currentCoordinator == self.localPeerID)
            if isCoordinatorSelf {
                let selfQuality = SyncQuality(offsetNs: 0, roundTripDelayNs: 0, confidence: 1.0)
                return SyncSnapshot(
                    state: .synced(offset: 0.0, quality: selfQuality),
                    offset: 0.0,
                    quality: selfQuality,
                    lastSyncedAt: captured,
                    capturedAt: captured,
                    staleAfterNs: self.configuration.syncStaleAfterNs
                )
            }

            let q: SyncQuality? = {
                if case .synced(_, let quality) = self.lastSyncState { return quality }
                return nil
            }()
            let off: TimeInterval = {
                if case .synced(let offset, _) = self.lastSyncState { return offset }
                return 0.0
            }()
            return SyncSnapshot(
                state: self.lastSyncState,
                offset: off,
                quality: q,
                lastSyncedAt: self.lastSyncedAtNs,
                capturedAt: captured,
                staleAfterNs: self.configuration.syncStaleAfterNs
            )
        }
    }

    /// FailoverTransport 使用時のみ非 nil。現在 active な Transport の label を返す。
    public var activeTransportLabel: String? {
        let current = lock.withLock { transport }
        return (current as? FailoverTransport)?.activeLabel
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

    // MARK: - Private: Sync State Cache

    /// lock 配下に保持される直近の同期状態 (currentSync の元データ)
    private var lastSyncState: SyncState = .idle
    /// lock 配下に保持される直近の .synced 遷移時刻 (CLOCK_MONOTONIC ns)
    private var lastSyncedAtNs: UInt64? = nil
    private var statusRegistry: StatusRegistry?
    private var statusReceiver: StatusReceiver?
    private var heartbeatMonitor: HeartbeatMonitor?
    private var eventScheduler: EventScheduler?

    // MARK: - Private: Tasks

    private var coordinationTask: Task<Void, Never>?
    private var syncResponderTask: Task<Void, Never>?
    private var syncStateForwardTask: Task<Void, Never>?
    private var heartbeatRoutingTask: Task<Void, Never>?
    private var statusPushRoutingTask: Task<Void, Never>?
    private var heartbeatElectionTask: Task<Void, Never>?
    private var driftJumpRoutingTask: Task<Void, Never>?

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

            let router = CommandRouter(transport: newTransport, localPeerID: localPeerID)
            self.commandRouter = router

            let eng = NTPSyncEngine(
                transport: newTransport,
                localPeerID: localPeerID,
                configuration: configuration,
                syncResponseStream: router.syncResponses
            )
            self.syncEngine = eng

            let dm = DriftMonitor()
            self.driftMonitor = dm

            // EventScheduler — now クロージャは同期オフセット適用済み時刻を使う
            let scheduler = EventScheduler(
                now: { [weak self] in self?.now ?? 0 }
            )
            self.eventScheduler = scheduler

            // 自分自身は最初から既知ピアに含める
            knownPeers = [localPeerID]

            return newTransport
        }

        // Status / Heartbeat actors を構築（self を weak キャプチャして transport を参照）
        let registry = StatusRegistry(
            localPeerID: localPeerID,
            debounce: configuration.statusSendDebounce
        ) { [weak self] message in
            guard let tr = self?.lock.withLock({ self?.transport }) else { return }
            let data = MessageCodec.encode(message)
            try await tr.broadcast(data)
        }
        let receiver = StatusReceiver(debounce: configuration.statusReceiveDebounce)
        let heartbeat = HeartbeatMonitor(
            interval: configuration.heartbeatInterval,
            degradedAfter: configuration.degradedAfter,
            disconnectedAfter: configuration.disconnectedAfter
        ) { [weak self] in
            guard let tr = self?.lock.withLock({ self?.transport }) else { return }
            let data = MessageCodec.encode(Message.heartbeat)
            try await tr.broadcastUnreliable(data)
        }
        lock.withLock {
            self.statusRegistry = registry
            self.statusReceiver = receiver
            self.heartbeatMonitor = heartbeat
        }

        try await tr.start()

        syncStateContinuation.yield(.discovering)

        // HeartbeatMonitor を開始
        await heartbeat.start()

        // ルーティングタスク: heartbeat
        let router = lock.withLock { commandRouter! }
        let hbRoutingTask = Task {
            for await sender in router.heartbeatSenders {
                await heartbeat.heartbeatReceived(from: sender)
            }
        }
        // ルーティングタスク: statusPush
        let spRoutingTask = Task {
            for await (sender, generation, entries) in router.statusPushes {
                _ = await receiver.ingestPush(from: sender, generation: generation, entries: entries)
            }
        }
        // Phase 3a: heartbeat disconnected -> re-run election for TCP half-open cases
        let hbElectionTask = Task { [weak self] in
            guard let self else { return }
            for await event in heartbeat.events {
                if case .disconnected = event.state {
                    let router = self.lock.withLock { self.commandRouter }
                    router?.forgetPeer(event.peerID)
                    await self.reevaluateCoordination()
                }
            }
        }
        lock.withLock {
            self.heartbeatRoutingTask = hbRoutingTask
            self.statusPushRoutingTask = spRoutingTask
            self.heartbeatElectionTask = hbElectionTask
        }

        // syncEngine のステート更新を転送するタスク
        let eng = lock.withLock { syncEngine! }
        let dm = lock.withLock { driftMonitor! }

        // DriftMonitor のジャンプを EventScheduler に転送するタスク
        let scheduler = lock.withLock { eventScheduler! }
        let driftJumpTask = Task { [weak eng] in
            for await jump in dm.jumps {
                eng?.resetBackoff()
                await scheduler.handleJump(
                    oldOffsetNs: jump.oldOffsetNs,
                    newOffsetNs: jump.newOffsetNs
                )
            }
        }
        lock.withLock { self.driftJumpRoutingTask = driftJumpTask }
        let cont = syncStateContinuation
        let selfLock = self.lock
        let forwardTask = Task { [weak self] in
            for await state in eng.syncStateUpdates {
                cont.yield(state)
                selfLock.withLock {
                    self?.lastSyncState = state
                    if case .synced = state {
                        self?.lastSyncedAtNs = NTPSyncEngine.now()
                    }
                }
                if case .synced(let offset, let quality) = state {
                    dm.recordOffset(offset * 1_000_000_000)
                    let offsetNs = Int64(offset * 1_000_000_000)
                    try? await registry.setStatus(offsetNs, forKey: StatusKeys.syncOffset)
                    try? await registry.setStatus(quality, forKey: StatusKeys.syncQuality)
                }
            }
        }
        lock.withLock { self.syncStateForwardTask = forwardTask }

        // デバイス名を一度だけ配信
        let deviceName: String = {
            #if canImport(UIKit)
            return UIDevice.current.name
            #else
            return Host.current().localizedName ?? "Mac"
            #endif
        }()
        try? await registry.setStatus(deviceName, forKey: StatusKeys.deviceName)

        // メイン協調タスクを開始
        let coordTask = Task { [weak self] in
            guard let self else { return }
            await self.runCoordinationLoop(transport: tr)
        }
        lock.withLock { self.coordinationTask = coordTask }
    }

    /// 同期を停止する
    public func stop() async {
        let (coordTask, syncResponder, fwdTask, hbTask, spTask, hbElecTask, djTask, eng, tr, registry, receiver, heartbeat, sched) = lock.withLock {
            let c = coordinationTask; coordinationTask = nil
            let s = syncResponderTask; syncResponderTask = nil
            let f = syncStateForwardTask; syncStateForwardTask = nil
            let h = heartbeatRoutingTask; heartbeatRoutingTask = nil
            let sp = statusPushRoutingTask; statusPushRoutingTask = nil
            let he = heartbeatElectionTask; heartbeatElectionTask = nil
            let dj = driftJumpRoutingTask; driftJumpRoutingTask = nil
            let e = syncEngine
            let t = transport
            let reg = statusRegistry; statusRegistry = nil
            let rec = statusReceiver; statusReceiver = nil
            let hb = heartbeatMonitor; heartbeatMonitor = nil
            let sc = eventScheduler; eventScheduler = nil
            return (c, s, f, h, sp, he, dj, e, t, reg, rec, hb, sc)
        }

        coordTask?.cancel()
        syncResponder?.cancel()
        fwdTask?.cancel()
        hbTask?.cancel()
        spTask?.cancel()
        hbElecTask?.cancel()
        djTask?.cancel()

        await coordTask?.value
        await syncResponder?.value
        await fwdTask?.value
        await hbTask?.value
        await spTask?.value
        await hbElecTask?.value
        await djTask?.value

        await eng?.stop()
        await registry?.shutdown()
        await receiver?.shutdown()
        await heartbeat?.stop()
        await sched?.shutdown()
        await tr?.stop()

        lock.withLock {
            self.lastSyncState = .idle
            self.lastSyncedAtNs = nil
        }
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

    // MARK: - Status API

    /// 生バイト列のステータス値をセットする。フラッシュはデバウンスされる。
    public func setStatus(_ data: Data, forKey key: String) async {
        let registry = lock.withLock { statusRegistry }
        await registry?.setStatus(data, forKey: key)
    }

    /// Codable なステータス値をセットする（binary plist エンコード）。エンコード失敗時に throw。
    public func setStatus<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        guard let registry = lock.withLock({ statusRegistry }) else { return }
        try await registry.setStatus(value, forKey: key)
    }

    /// 指定ピアの最新ステータスを返す。
    public func status(of peer: PeerID) async -> RemotePeerStatus? {
        let receiver = lock.withLock { statusReceiver }
        return await receiver?.status(of: peer)
    }

    /// デバウンスされたリモートステータス更新ストリーム。
    public var statusUpdates: AsyncStream<RemotePeerStatus> {
        lock.withLock { statusReceiver }?.updates ?? AsyncStream { $0.finish() }
    }

    /// 指定ピアのハートビート由来の接続状態を返す。
    public func connectionState(of peer: PeerID) async -> ConnectionState? {
        let hb = lock.withLock { heartbeatMonitor }
        return await hb?.currentState(of: peer)
    }

    /// ハートビート接続状態遷移ストリーム。
    public var connectionEvents: AsyncStream<HeartbeatMonitor.Event> {
        lock.withLock { heartbeatMonitor }?.events ?? AsyncStream { $0.finish() }
    }

    // MARK: - EventScheduler API

    /// 同期済み時刻でアクションを予約する。
    ///
    /// ガード順:
    /// 1. PeerClock 未起動 → `notStarted`
    /// 2. 未同期 or 鮮度切れ → `notSynchronized`
    /// 3. quality < minSyncQuality → `qualityBelowThreshold`
    /// 4. 過去時刻で遅延 > lateTolerance → `deadlineExceeded`
    ///
    /// - parameter atSyncedTime: `clock.now` と同じ時間軸のナノ秒値
    /// - parameter lateTolerance: 過去時刻 schedule で許容する遅延幅。デフォルト 0 (拒否)。
    public func schedule(
        atSyncedTime: UInt64,
        lateTolerance: Duration = .zero,
        _ action: @Sendable @escaping () -> Void
    ) async throws -> ScheduledEventHandle {
        // (0) 未起動チェック
        guard let scheduler = lock.withLock({ eventScheduler }) else {
            throw PeerClockError.notStarted
        }

        // (1) 同期チェック
        let snapshot = self.currentSync
        guard snapshot.isSynchronized else {
            throw PeerClockError.notSynchronized
        }

        // (2) 品質チェック
        if let quality = snapshot.quality {
            let confidence = quality.confidence
            let threshold = configuration.minSyncQuality
            if confidence < threshold {
                throw PeerClockError.qualityBelowThreshold(quality: confidence, threshold: threshold)
            }
        }

        // (3) 過去時刻チェック
        let nowNs = self.now
        if atSyncedTime < nowNs {
            let lateNs = nowNs - atSyncedTime
            let toleranceNs = Self.nanoseconds(from: lateTolerance)
            if lateNs > toleranceNs {
                throw PeerClockError.deadlineExceeded(
                    lateBy: .nanoseconds(Int64(lateNs)),
                    tolerance: lateTolerance
                )
            }
        }

        let id = await scheduler.schedule(atSyncedTime: atSyncedTime, action)
        return ScheduledEventHandle(id: id, scheduler: scheduler)
    }

    /// Duration → ナノ秒変換 (内部用)
    private static func nanoseconds(from duration: Duration) -> UInt64 {
        let comps = duration.components
        let secNs = UInt64(max(0, comps.seconds)) * 1_000_000_000
        let attoNs = UInt64(max(0, comps.attoseconds / 1_000_000_000))
        return secNs &+ attoNs
    }

    /// スケジューラ通知ストリーム（クロックジャンプ警告など）。
    public var schedulerEvents: AsyncStream<SchedulerEvent> {
        lock.withLock { eventScheduler }?.schedulerEvents ?? AsyncStream { $0.finish() }
    }

    // MARK: - Private: Coordination Loop

    private func runCoordinationLoop(transport: any Transport) async {
        for await peers in transport.peers {
            guard !Task.isCancelled else { break }

            let (newPeerList, elec, eng, hb, prevKnown) = lock.withLock {
                () -> ([PeerID], CoordinatorElection?, NTPSyncEngine?, HeartbeatMonitor?, Set<PeerID>) in
                let prev = knownPeers
                knownPeers = peers
                return (Array(peers), election, syncEngine, heartbeatMonitor, prev)
            }

            guard let elec, let eng else { continue }

            let added = peers.subtracting(prevKnown)
            let removed = prevKnown.subtracting(peers)

            // ピア追加/削除を heartbeatMonitor に通知
            if let hb {
                for p in added where p != localPeerID {
                    await hb.peerJoined(p)
                }
                for p in removed where p != localPeerID {
                    await hb.peerLeft(p)
                }
            }

            // Phase 3a: flush local status once when new peers join
            if !added.isEmpty {
                let registry = lock.withLock { statusRegistry }
                if let registry {
                    let jitterNs = UInt64.random(in: 0...100_000_000)
                    try? await Task.sleep(nanoseconds: jitterNs)
                    await registry.flushNow()
                }
            }

            // ピアリストをストリームに流す（connectionState をハートビート由来にする）
            var peerList: [Peer] = []
            for peerID in newPeerList {
                let connState: ConnectionState
                if let hb {
                    connState = await hb.currentState(of: peerID) ?? .connected
                } else {
                    connState = .connected
                }
                peerList.append(Peer(
                    id: peerID,
                    name: peerID.description,
                    status: PeerStatus(
                        peerID: peerID,
                        connectionState: connState,
                        deviceInfo: DeviceInfo(
                            name: peerID.description,
                            platform: .iOS,
                            storageAvailable: 0
                        ),
                        generation: 0
                    )
                ))
            }
            peersContinuation.yield(peerList)

            // コーディネーター選出を更新
            // Phase 3a: exclude heartbeat-disconnected peers from election
            var effectivePeers: [PeerID] = []
            if let hb {
                for p in newPeerList {
                    let state = await hb.currentState(of: p)
                    if state != ConnectionState.disconnected {
                        effectivePeers.append(p)
                    }
                }
            } else {
                effectivePeers = newPeerList
            }
            elec.updatePeers(effectivePeers + [localPeerID])
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

    /// Phase 3a: re-evaluate election when heartbeat reports a disconnect.
    /// runCoordinationLoop only fires on transport.peers changes; this handles
    /// TCP half-open cases where only the heartbeat sees the disconnect.
    private func reevaluateCoordination() async {
        let (peers, elec, eng, hb) = lock.withLock {
            (knownPeers, election, syncEngine, heartbeatMonitor)
        }
        guard let elec, let eng else { return }

        var effective: [PeerID] = []
        if let hb {
            for p in peers {
                let state = await hb.currentState(of: p)
                if state != ConnectionState.disconnected {
                    effective.append(p)
                }
            }
        } else {
            effective = Array(peers)
        }

        let prevCoordinator = lock.withLock { currentCoordinator }
        elec.updatePeers(effective + [localPeerID])
        let newCoordinator = elec.coordinator
        guard newCoordinator != prevCoordinator else { return }

        lock.withLock { currentCoordinator = newCoordinator }

        if elec.isCoordinator {
            await eng.stop()
            guard let transport = lock.withLock({ transport }) else { return }
            startSyncResponder(transport: transport)
        } else if let newCoordinator {
            lock.withLock { () -> Task<Void, Never>? in
                let t = syncResponderTask
                syncResponderTask = nil
                return t
            }?.cancel()

            await eng.stop()
            await eng.start(coordinator: newCoordinator)
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

        let syncStream = lock.withLock { commandRouter?.syncRequests }
        guard let syncStream else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            for await (sender, message) in syncStream {
                guard !Task.isCancelled else { break }
                guard case .ping(_, let t0) = message else { continue }

                let t1 = NTPSyncEngine.now()
                let t2 = NTPSyncEngine.now()
                let response = Message.pong(peerID: self.localPeerID, t0: t0, t1: t1, t2: t2)
                let responseData = MessageCodec.encode(response)
                try? await transport.send(responseData, to: sender)
            }
        }

        lock.withLock { syncResponderTask = task }
    }
}
