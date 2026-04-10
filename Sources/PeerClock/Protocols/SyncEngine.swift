import Foundation

/// Protocol for clock synchronization engines.
public protocol SyncEngine: Sendable {
    /// Current clock offset relative to the coordinator, in seconds.
    var currentOffset: TimeInterval { get }
    /// Starts synchronizing against the given coordinator peer.
    func start(coordinator: PeerID) async
    /// Stops synchronization.
    func stop() async
    /// Stream of sync state changes.
    var syncStateUpdates: AsyncStream<SyncState> { get }
}
