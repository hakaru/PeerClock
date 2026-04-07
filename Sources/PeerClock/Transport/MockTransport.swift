import Foundation

public actor MockNetwork {

    private var transports: [PeerID: MockTransport] = [:]

    public init() {}

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
        let receivers = transports
            .filter { $0.key != sender }
            .map(\.value)

        for transport in receivers {
            await send(
                data,
                from: sender,
                to: transport.localPeerID,
                latency: latency,
                packetDropProbability: packetDropProbability
            )
        }
    }

    private func publishPeerSnapshots() async {
        let allPeerIDs = Set(transports.keys)
        for transport in transports.values {
            var peers = allPeerIDs
            peers.remove(transport.localPeerID)
            transport.updatePeers(peers)
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

    public func send(_ data: Data, to peer: PeerID) async throws {
        await network.send(
            data,
            from: localPeerID,
            to: peer,
            latency: latency,
            packetDropProbability: packetDropProbability
        )
    }

    public func broadcast(_ data: Data) async throws {
        await network.broadcast(
            data,
            from: localPeerID,
            latency: latency,
            packetDropProbability: packetDropProbability
        )
    }

    fileprivate func updatePeers(_ peers: Set<PeerID>) {
        peersContinuation.yield(peers)
    }

    fileprivate func receive(from sender: PeerID, data: Data) {
        incomingMessagesContinuation.yield((sender, data))
    }
}
