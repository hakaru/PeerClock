import Foundation
import Network

/// Network.framework transport used on real devices.
///
/// Phase 1.1 only needs this type to satisfy the transport surface; tests use `MockTransport`.
public final class WiFiTransport: Transport, @unchecked Sendable {

    private let localPeerID: PeerID
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "PeerClock.WiFiTransport")
    private let lock = NSLock()

    private var discovery: Discovery?
    private var connections: [PeerID: NWConnection] = [:]
    private var peerSnapshots: Set<PeerID> = []
    private var discoveryTask: Task<Void, Never>?

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingMessagesContinuation: AsyncStream<(PeerID, Data)>.Continuation

    public init(localPeerID: PeerID, configuration: Configuration) {
        self.localPeerID = localPeerID
        self.configuration = configuration

        var peersContinuation: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersContinuation = $0 }
        self.peersContinuation = peersContinuation

        var incomingContinuation: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingContinuation = $0 }
        self.incomingMessagesContinuation = incomingContinuation
    }

    public func start() async throws {
        let discovery = try Discovery(serviceType: configuration.serviceType, localPeerID: localPeerID)
        discovery.inboundConnectionHandler = { [weak self] connection in
            self?.handleInboundConnection(connection)
        }
        self.discovery = discovery
        discovery.start()

        discoveryTask = Task { [weak self] in
            guard let self else { return }
            for await event in discovery.events {
                guard !Task.isCancelled else { break }
                switch event {
                case .peerFound(let endpoint, let peerID):
                    guard let peerID else { continue }
                    self.connect(to: endpoint, peerID: peerID)
                case .peerLost(_, let peerID):
                    guard let peerID else { continue }
                    self.removePeer(peerID)
                case .listenerReady:
                    break
                }
            }
        }
    }

    public func stop() async {
        let (connections, task, discovery) = lock.withLock { () -> ([NWConnection], Task<Void, Never>?, Discovery?) in
            let connections = Array(self.connections.values)
            self.connections.removeAll()
            self.peerSnapshots.removeAll()
            let task = self.discoveryTask
            self.discoveryTask = nil
            let discovery = self.discovery
            self.discovery = nil
            return (connections, task, discovery)
        }

        task?.cancel()
        discovery?.stop()
        connections.forEach { $0.cancel() }
        peersContinuation.finish()
        incomingMessagesContinuation.finish()
    }

    public func send(_ data: Data, to peer: PeerID) async throws {
        guard let connection = lock.withLock({ connections[peer] }) else {
            return
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lengthPrefix = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }
            connection.send(content: lengthPrefix + data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public func broadcast(_ data: Data) async throws {
        let peers = lock.withLock { Array(peerSnapshots) }
        for peer in peers {
            try await send(data, to: peer)
        }
    }

    private func connect(to endpoint: NWEndpoint, peerID: PeerID) {
        guard peerID != localPeerID else { return }
        let shouldConnect = lock.withLock { () -> Bool in
            if connections[peerID] != nil {
                return false
            }
            return true
        }
        guard shouldConnect else { return }

        attemptConnect(to: endpoint, peerID: peerID, attempt: 1)
    }

    private func attemptConnect(to endpoint: NWEndpoint, peerID: PeerID, attempt: Int) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        lock.withLock {
            connections[peerID] = connection
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.addPeer(peerID)
                let handshake = self.localPeerID.data
                connection.send(content: handshake, completion: .contentProcessed { _ in })
                self.receiveLength(from: peerID, connection: connection)
            case .failed, .cancelled:
                let maxAttempts = self.configuration.reconnectMaxAttempts
                let retryInterval = self.configuration.reconnectRetryInterval
                if attempt < maxAttempts {
                    self.lock.withLock {
                        if self.connections[peerID] === connection {
                            self.connections.removeValue(forKey: peerID)
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                        guard let self else { return }
                        let stillWanted = self.lock.withLock { self.connections[peerID] == nil }
                        if stillWanted {
                            self.attemptConnect(to: endpoint, peerID: peerID, attempt: attempt + 1)
                        }
                    }
                } else {
                    self.removePeer(peerID)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func handleInboundConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] data, _, _, error in
            guard let self, let data, error == nil, let peerID = try? PeerID(data: data) else {
                connection.cancel()
                return
            }

            let oldConnection = self.lock.withLock { () -> NWConnection? in
                let old = self.connections[peerID]
                self.connections[peerID] = connection
                return old
            }
            oldConnection?.cancel()

            self.addPeer(peerID)
            self.receiveLength(from: peerID, connection: connection)
        }
    }

    private func receiveLength(from peerID: PeerID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == 4, error == nil else {
                if isComplete || error != nil {
                    self.removePeer(peerID)
                    connection.cancel()
                }
                return
            }

            let length = data.withUnsafeBytes { rawBuffer -> UInt32 in
                rawBuffer.load(as: UInt32.self).bigEndian
            }
            self.receiveBody(length: Int(length), from: peerID, connection: connection)
        }
    }

    private func receiveBody(length: Int, from peerID: PeerID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else {
                if isComplete || error != nil {
                    self.removePeer(peerID)
                    connection.cancel()
                }
                return
            }

            self.incomingMessagesContinuation.yield((peerID, data))
            self.receiveLength(from: peerID, connection: connection)
        }
    }

    private func addPeer(_ peerID: PeerID) {
        let snapshot = lock.withLock { () -> Set<PeerID> in
            peerSnapshots.insert(peerID)
            return peerSnapshots
        }
        peersContinuation.yield(snapshot)
    }

    private func removePeer(_ peerID: PeerID) {
        let snapshot = lock.withLock { () -> Set<PeerID> in
            peerSnapshots.remove(peerID)
            connections.removeValue(forKey: peerID)
            return peerSnapshots
        }
        peersContinuation.yield(snapshot)
    }
}
