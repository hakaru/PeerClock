import Foundation
import Network
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "StarTransport")

/// Star-topology Transport. Depending on whether the local node is elected
/// host or client, delegates to StarHost or StarClient internally.
///
/// Role transitions are driven externally:
/// - `promoteToHost()` — used by HostElection (Plan B) or tests
/// - `demoteToClient(connectingTo:hostPeerID:)` — ditto
///
/// `start()` is a no-op for Plan A; Plan B will wire election logic here.
public final class StarTransport: Transport, @unchecked Sendable {

    // MARK: - Transport protocol streams

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingContinuation: AsyncStream<(PeerID, Data)>.Continuation

    // MARK: - Role

    public enum Role: Sendable, Equatable {
        case undecided
        case host
        case client(hostPeerID: PeerID)
    }

    // MARK: - Internal state (lock-protected)

    private let lock = NSLock()
    private var host: StarHost?
    private var client: StarClient?
    private var currentRole: Role = .undecided

    // Background tasks that forward stream events from StarHost / StarClient
    private var hostForwardTask: Task<Void, Never>?
    private var clientForwardTask: Task<Void, Never>?

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public static let `default` = Configuration()
        public init() {}
    }

    private let localPeerID: PeerID
    private let configuration: Configuration

    // MARK: - Init

    public init(localPeerID: PeerID, configuration: Configuration = .default) {
        self.localPeerID = localPeerID
        self.configuration = configuration

        var pc: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { pc = $0 }
        self.peersContinuation = pc

        var ic: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { ic = $0 }
        self.incomingContinuation = ic
    }

    // MARK: - Transport protocol

    /// No-op for Plan A. Plan B will start HostElection here.
    public func start() async throws {
        logger.info("[StarTransport] start() — role will be assigned by election (Plan B)")
    }

    public func stop() async {
        // Snapshot mutable state inside lock before use
        let (capturedHost, capturedClient, capturedHostTask, capturedClientTask) = lock.withLock {
            let h = host
            let c = client
            let ht = hostForwardTask
            let ct = clientForwardTask
            host = nil
            client = nil
            hostForwardTask = nil
            clientForwardTask = nil
            currentRole = .undecided
            return (h, c, ht, ct)
        }

        capturedHostTask?.cancel()
        capturedClientTask?.cancel()
        capturedHost?.stop()
        capturedClient?.close()

        peersContinuation.yield([])
        // Streams remain open — StarTransport can be restarted after stop
        logger.info("[StarTransport] stopped")
    }

    public func send(_ data: Data, to peer: PeerID) async throws {
        let target: SendTarget = lock.withLock { () -> SendTarget in
            switch currentRole {
            case .host:
                return .host(self.host)
            case .client:
                return .client(self.client)
            case .undecided:
                return .none
            }
        }
        switch target {
        case .host(let h):
            guard let h else { throw StarTransportError.notStarted }
            // TODO(Plan B): resolve peerID → clientID for true unicast.
            // For Plan A, host-mode send falls back to broadcast.
            h.broadcast(data)
        case .client(let c):
            guard let c else { throw StarTransportError.notStarted }
            c.send(data)
        case .none:
            throw StarTransportError.notStarted
        }
    }

    public func broadcast(_ data: Data) async throws {
        let target: SendTarget = lock.withLock { () -> SendTarget in
            switch currentRole {
            case .host:
                return .host(self.host)
            case .client:
                return .client(self.client)
            case .undecided:
                return .none
            }
        }
        switch target {
        case .host(let h):
            guard let h else { throw StarTransportError.notStarted }
            h.broadcast(data)
        case .client(let c):
            guard let c else { throw StarTransportError.notStarted }
            // Client has a single upstream connection; send to host
            c.send(data)
        case .none:
            throw StarTransportError.notStarted
        }
    }

    private enum SendTarget {
        case host(StarHost?)
        case client(StarClient?)
        case none
    }

    // MARK: - Role promotion APIs (used by HostElection in Plan B)

    /// Promotes this node to host: starts a StarHost NWListener and begins
    /// forwarding events into the `peers` and `incomingMessages` streams.
    /// Returns the underlying NWListener so callers (e.g. HostElection) can
    /// attach Bonjour advertising via BonjourAdvertiser.start(listener:).
    @discardableResult
    public func promoteToHost() async throws -> NWListener {
        // Cleanup previous role first
        let (oldHost, oldClient, oldHostTask, oldClientTask) = lock.withLock { () -> (StarHost?, StarClient?, Task<Void, Never>?, Task<Void, Never>?) in
            let h = host
            let c = client
            let ht = hostForwardTask
            let ct = clientForwardTask
            host = nil
            client = nil
            hostForwardTask = nil
            clientForwardTask = nil
            return (h, c, ht, ct)
        }
        oldHostTask?.cancel()
        oldClientTask?.cancel()
        oldHost?.stop()
        oldClient?.close()

        // Now promote
        let h = StarHost()
        let listener = try h.start()
        let forwardTask = Task<Void, Never> { [weak self] in
            await self?.forwardHostEvents(from: h)
        }
        lock.withLock {
            self.host = h
            self.currentRole = .host
            self.hostForwardTask = forwardTask
        }

        logger.info("[StarTransport] promoted to host (localPeerID=\(self.localPeerID.description, privacy: .public))")
        return listener
    }

    /// Demotes this node to client, connecting to the given endpoint.
    public func demoteToClient(connectingTo endpoint: NWEndpoint, hostPeerID: PeerID) async {
        // Cleanup previous role first
        let (oldHost, oldClient, oldHostTask, oldClientTask) = lock.withLock { () -> (StarHost?, StarClient?, Task<Void, Never>?, Task<Void, Never>?) in
            let h = host
            let c = client
            let ht = hostForwardTask
            let ct = clientForwardTask
            host = nil
            client = nil
            hostForwardTask = nil
            clientForwardTask = nil
            return (h, c, ht, ct)
        }
        oldHostTask?.cancel()
        oldClientTask?.cancel()
        oldHost?.stop()
        oldClient?.close()

        // Now demote
        let c = StarClient()
        c.connect(to: endpoint)
        let forwardTask = Task<Void, Never> { [weak self] in
            await self?.forwardClientEvents(from: c, hostPeerID: hostPeerID)
        }
        lock.withLock {
            self.client = c
            self.currentRole = .client(hostPeerID: hostPeerID)
            self.clientForwardTask = forwardTask
        }

        logger.info("[StarTransport] demoted to client of \(hostPeerID.description, privacy: .public)")
    }

    // MARK: - Event forwarding (private)

    /// Consumes `StarHost.clients` and `StarHost.incomingMessages`, translating
    /// them into the Transport-protocol streams.
    private func forwardHostEvents(from h: StarHost) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                for await clients in h.clients {
                    // Snapshot: emit PeerIDs of clients that have a known peerID
                    let peerSet = Set(clients.compactMap(\.peerID))
                    self?.peersContinuation.yield(peerSet)
                }
            }
            group.addTask { [weak self] in
                // Forward incoming messages — use a placeholder PeerID for unmapped clients (Plan B TODO)
                for await (clientID, data) in h.incomingMessages {
                    // TODO(Plan B): resolve clientID → PeerID via peerID→clientID map.
                    // For Plan A, fabricate a PeerID from the clientID bytes to preserve uniqueness.
                    let placeholder = PeerID(clientID)
                    self?.incomingContinuation.yield((placeholder, data))
                }
            }
            await group.waitForAll()
        }
    }

    /// Consumes `StarClient.incomingMessages` and `StarClient.stateStream`,
    /// translating them into the Transport-protocol streams.
    private func forwardClientEvents(from c: StarClient, hostPeerID: PeerID) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                // Forward state changes → peers stream
                for await state in c.stateStream {
                    switch state {
                    case .ready:
                        self?.peersContinuation.yield([hostPeerID])
                    case .closed:
                        self?.peersContinuation.yield([])
                    default:
                        break
                    }
                }
            }
            group.addTask { [weak self] in
                // Forward incoming messages from host
                for await data in c.incomingMessages {
                    self?.incomingContinuation.yield((hostPeerID, data))
                }
            }
            await group.waitForAll()
        }
    }

    // MARK: - Test-only accessors

    #if DEBUG
    internal var hostForTest: StarHost? { lock.withLock { host } }
    #endif
}

// MARK: - Error

public enum StarTransportError: Error, Sendable {
    /// Operation attempted before a role has been assigned.
    case notStarted
}
