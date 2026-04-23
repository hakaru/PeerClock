import Foundation

public actor MockNetwork {

    private var transports: [PeerID: MockTransport] = [:]
    private var disconnected: Set<PeerID> = []

    public init() {}

    public func simulateDisconnect(peer: PeerID) async {
        guard transports[peer] != nil else { return }
        disconnected.insert(peer)
        await publishPeerSnapshots()
    }

    public func simulateReconnect(peer: PeerID) async {
        disconnected.remove(peer)
        await publishPeerSnapshots()
    }

    public func createTransport(
        for peerID: PeerID,
        latency: Duration = .zero,
        packetDropProbability: Double = 0
    ) -> MockTransport {
        MockTransport(
            localPeerID: peerID,
            network: self,
            latency: latency,
            packetDropProbability: packetDropProbability
        )
    }

    func register(_ transport: MockTransport) async {
        transports[transport.localPeerID] = transport
        await publishPeerSnapshots()
    }

    func unregister(peerID: PeerID) async {
        transports.removeValue(forKey: peerID)
        await publishPeerSnapshots()
    }

    func send(
        _ data: Data,
        from sender: PeerID,
        to receiver: PeerID,
        latency: Duration,
        packetDropProbability: Double
    ) async {
        guard !disconnected.contains(sender), !disconnected.contains(receiver) else { return }
        guard Double.random(in: 0...1) >= packetDropProbability else {
            return
        }
        guard let transport = transports[receiver] else {
            return
        }

        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
        transport.receive(from: sender, data: data)
    }

    func broadcast(
        _ data: Data,
        from sender: PeerID,
        latency: Duration,
        packetDropProbability: Double
    ) async {
        guard !disconnected.contains(sender) else { return }
        let receivers = transports.filter { $0.key != sender && !disconnected.contains($0.key) }.map(\.value)

        for transport in receivers {
            await send(data, from: sender, to: transport.localPeerID, latency: latency, packetDropProbability: packetDropProbability)
        }
    }

    private func publishPeerSnapshots() async {
        let liveIDs = Set(transports.keys).subtracting(disconnected)
        for transport in transports.values {
            if disconnected.contains(transport.localPeerID) {
                transport.updatePeers([])
            } else {
                var peers = liveIDs
                peers.remove(transport.localPeerID)
                transport.updatePeers(peers)
            }
        }
    }
}

public final class MockTransport: Transport, @unchecked Sendable {

    public let localPeerID: PeerID

    private let network: MockNetwork
    private let latency: Duration
    private let packetDropProbability: Double
    private let lock = NSLock()

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingMessagesContinuation: AsyncStream<(PeerID, Data)>.Continuation
    private var isStarted = false

    public init(
        localPeerID: PeerID,
        network: MockNetwork,
        latency: Duration = .zero,
        packetDropProbability: Double = 0
    ) {
        self.localPeerID = localPeerID
        self.network = network
        self.latency = latency
        self.packetDropProbability = packetDropProbability

        var peersContinuation: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersContinuation = $0 }
        self.peersContinuation = peersContinuation

        var incomingMessagesContinuation: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingMessagesContinuation = $0 }
        self.incomingMessagesContinuation = incomingMessagesContinuation
    }

    public func start() async throws {
        let shouldStart = lock.withLock { () -> Bool in
            guard !isStarted else { return false }
            isStarted = true
            return true
        }
        guard shouldStart else { return }
        await network.register(self)
    }

    public func stop() async {
        let shouldStop = lock.withLock { () -> Bool in
            guard isStarted else { return false }
            isStarted = false
            return true
        }
        guard shouldStop else { return }

        await network.unregister(peerID: localPeerID)
        peersContinuation.finish()
        incomingMessagesContinuation.finish()
    }

    public func broadcast(_ data: Data) async throws {
        await network.broadcast(
            data,
            from: localPeerID,
            latency: latency,
            packetDropProbability: packetDropProbability
        )
    }

    // Phase 2a: same path as reliable; tests don't yet distinguish channels.
    public func broadcastUnreliable(_ data: Data) async throws {
        try await broadcast(data)
    }

    fileprivate func updatePeers(_ peers: Set<PeerID>) {
        peersContinuation.yield(peers)
    }

    fileprivate func receive(from sender: PeerID, data: Data) {
        incomingMessagesContinuation.yield((sender, data))
    }
}
