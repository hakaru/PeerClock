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

    /// Observability events originating from the transport stack
    /// (star handshake failures, timeouts, disconnects). Mesh runtime
    /// produces no events; star/auto runtimes forward from the inner
    /// `StarTransport`.
    var connectionEvents: AsyncStream<ConnectionEvent> { get }

    /// Used by `AutoRuntime` to observe peer count without exposing
    /// transport internals.
    var currentPeerCount: Int { get async }

    /// Stream of transition-ready events. `PeerClock` listens and rebuilds
    /// services against the new transport when a transition fires. Mesh and
    /// Star runtimes yield nothing; only `AutoRuntime` emits.
    var transitionEvents: AsyncStream<TopologyTransition> { get }
}
