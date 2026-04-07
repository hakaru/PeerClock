import Foundation

/// Determines which peer acts as the clock-sync coordinator.
///
/// The coordinator is always the peer with the smallest `PeerID`.
/// When the peer list changes, `updatePeers(_:)` recalculates the coordinator
/// and emits the new value via `coordinatorUpdates` if it changed.
public final class CoordinatorElection: @unchecked Sendable {

    // MARK: - Private state

    private let lock = NSLock()
    private var _coordinator: PeerID?
    private let localPeerID: PeerID
    private var continuation: AsyncStream<PeerID?>.Continuation?

    // MARK: - Public interface

    /// The current coordinator, or `nil` if no peers are known.
    public var coordinator: PeerID? {
        lock.withLock { _coordinator }
    }

    /// `true` when the local peer is the current coordinator.
    public var isCoordinator: Bool {
        lock.withLock { _coordinator == localPeerID }
    }

    /// Emits the new coordinator `PeerID?` every time it changes.
    public let coordinatorUpdates: AsyncStream<PeerID?>

    // MARK: - Init

    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID

        var storedContinuation: AsyncStream<PeerID?>.Continuation!
        coordinatorUpdates = AsyncStream { continuation in
            storedContinuation = continuation
        }
        self.continuation = storedContinuation
    }

    // MARK: - Update

    /// Recalculates the coordinator from the given peer list.
    ///
    /// Emits to `coordinatorUpdates` only when the coordinator actually changes.
    public func updatePeers(_ peers: [PeerID]) {
        let newCoordinator = peers.min()
        let changed: Bool = lock.withLock {
            guard newCoordinator != _coordinator else { return false }
            _coordinator = newCoordinator
            return true
        }
        if changed {
            continuation?.yield(newCoordinator)
        }
    }
}
