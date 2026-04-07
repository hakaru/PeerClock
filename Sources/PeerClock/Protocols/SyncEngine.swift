import Foundation

public protocol SyncEngine: Sendable {
    var currentOffset: TimeInterval { get }
    func start(coordinator: PeerID) async
    func stop() async
    var syncStateUpdates: AsyncStream<SyncState> { get }
}
