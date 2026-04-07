import Foundation

// MARK: - MockNetwork

/// テスト用の仮想ネットワーク。複数のMockTransportを管理し、ピア間のメッセージ配送をシミュレートする。
public final class MockNetwork: Sendable {

    private let state = MutableState()

    public init() {}

    /// 指定したPeerID用のMockTransportを生成し、ネットワークに登録する。
    public func createTransport(for peerID: PeerID) -> MockTransport {
        let transport = MockTransport(localPeerID: peerID, network: self)
        state.withLock { s in
            s.transports[peerID] = transport
        }
        return transport
    }

    /// 送信者から受信者へデータを配送する。
    func deliver(from sender: PeerID, to receiver: PeerID, data: Data, reliable: Bool) {
        let transport = state.withLock { s in s.transports[receiver] }
        transport?.receive(from: sender, data: data, reliable: reliable)
    }

    /// 送信者を除く全ピアへ信頼性のあるデータをブロードキャストする。
    func broadcastReliable(from sender: PeerID, data: Data) {
        let targets = state.withLock { s in
            s.transports.filter { $0.key != sender }.values.map { $0 }
        }
        for transport in targets {
            transport.receive(from: sender, data: data, reliable: true)
        }
    }

    /// 指定したピアがネットワークに参加したことを全ピアに通知する。
    /// 参加ピアには既存の全ピアを通知し、既存ピアには参加ピアを通知する。
    public func simulateJoin(_ peerID: PeerID) {
        let (joiningTransport, existingTransports) = state.withLock { s -> (MockTransport?, [MockTransport]) in
            let joining = s.transports[peerID]
            let existing = s.transports.filter { $0.key != peerID }.values.map { $0 }
            return (joining, Array(existing))
        }

        // 既存ピアに参加ピアを通知する
        for transport in existingTransports {
            transport.emitConnectionEvent(.peerJoined(peerID))
        }

        // 参加ピアに既存の全ピアを通知する
        for transport in existingTransports {
            joiningTransport?.emitConnectionEvent(.peerJoined(transport.localPeerID))
        }
    }

    /// 指定したピアがネットワークから離脱したことを残りの全ピアに通知する。
    public func simulateLeave(_ peerID: PeerID) {
        let remainingTransports = state.withLock { s -> [MockTransport] in
            Array(s.transports.filter { $0.key != peerID }.values)
        }

        for transport in remainingTransports {
            transport.emitConnectionEvent(.peerLeft(peerID))
        }
    }

    /// ネットワーク上の全PeerIDリスト。
    public var allPeerIDs: [PeerID] {
        state.withLock { s in Array(s.transports.keys) }
    }
}

// MARK: - MockNetwork.MutableState

extension MockNetwork {

    fileprivate final class MutableState: @unchecked Sendable {
        private let lock = NSLock()
        var transports: [PeerID: MockTransport] = [:]

        func withLock<T>(_ body: (MutableState) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }
}

// MARK: - MockTransport

/// Transport プロトコルのテスト用実装。MockNetwork を通じてメッセージを配送する。
public final class MockTransport: Transport, @unchecked Sendable {

    public let localPeerID: PeerID

    // MARK: Streams & Continuations

    public let unreliableMessages: AsyncStream<(PeerID, Data)>
    public let reliableMessages: AsyncStream<(PeerID, Data)>
    public let connectionEvents: AsyncStream<ConnectionEvent>

    private let unreliableContinuation: AsyncStream<(PeerID, Data)>.Continuation
    private let reliableContinuation: AsyncStream<(PeerID, Data)>.Continuation
    private let connectionContinuation: AsyncStream<ConnectionEvent>.Continuation

    // MARK: State

    private let lock = NSLock()
    private var _connectedPeers: Set<PeerID> = []
    private weak var _network: MockNetwork?

    public var connectedPeers: [PeerID] {
        lock.withLock { Array(_connectedPeers) }
    }

    // MARK: Init

    init(localPeerID: PeerID, network: MockNetwork) {
        self.localPeerID = localPeerID

        var unreliableCont: AsyncStream<(PeerID, Data)>.Continuation!
        var reliableCont: AsyncStream<(PeerID, Data)>.Continuation!
        var connectionCont: AsyncStream<ConnectionEvent>.Continuation!

        unreliableMessages = AsyncStream { unreliableCont = $0 }
        reliableMessages = AsyncStream { reliableCont = $0 }
        connectionEvents = AsyncStream { connectionCont = $0 }

        unreliableContinuation = unreliableCont
        reliableContinuation = reliableCont
        connectionContinuation = connectionCont

        _network = network
    }

    // MARK: Transport lifecycle

    public func start() throws {}
    public func stop() {}

    // MARK: Internal

    /// 受信メッセージを適切なストリームに流す。
    func receive(from sender: PeerID, data: Data, reliable: Bool) {
        if reliable {
            reliableContinuation.yield((sender, data))
        } else {
            unreliableContinuation.yield((sender, data))
        }
    }

    /// 接続イベントを発行し、connectedPeers セットを更新する。
    func emitConnectionEvent(_ event: ConnectionEvent) {
        lock.withLock {
            switch event {
            case .peerJoined(let peerID):
                _connectedPeers.insert(peerID)
            case .peerLeft(let peerID):
                _connectedPeers.remove(peerID)
            case .transportDegraded, .transportRestored:
                break
            }
        }
        connectionContinuation.yield(event)
    }

    // MARK: Transport

    public func sendUnreliable(_ data: Data, to peer: PeerID) async throws {
        let network = lock.withLock { _network }
        network?.deliver(from: localPeerID, to: peer, data: data, reliable: false)
    }

    public func sendReliable(_ data: Data, to peer: PeerID) async throws {
        let network = lock.withLock { _network }
        network?.deliver(from: localPeerID, to: peer, data: data, reliable: true)
    }

    public func broadcastReliable(_ data: Data) async throws {
        let network = lock.withLock { _network }
        network?.broadcastReliable(from: localPeerID, data: data)
    }
}
