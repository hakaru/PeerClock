import Foundation

/// Adapter that owns the per-topology component stack
/// (transport + election + router + bonjour) behind the `PeerClock` facade.
///
/// One runtime is active at a time. The facade delegates `start`/`stop`
/// and exposes merged streams.
internal protocol TopologyRuntime: AnyObject, Sendable {
    func start() async throws
    func stop() async

    var transport: any Transport { get }
    var peerStream: AsyncStream<[Peer]> { get }
    var commandStream: AsyncStream<(PeerID, Command)> { get }

    /// Used by `AutoRuntime` to observe peer count without exposing
    /// transport internals.
    var currentPeerCount: Int { get async }
}
