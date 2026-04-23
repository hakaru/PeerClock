import Foundation

/// Owns the mesh-topology transport lifecycle behind the ``PeerClock`` facade.
///
/// Phase 2 scope: transport lifecycle only. `CommandRouter`, `NTPSyncEngine`,
/// `HeartbeatMonitor`, `StatusRegistry`, and the peer-forwarding coordination
/// loop remain owned by ``PeerClock`` itself and are wired against
/// `runtime.transport` after `start()`.
///
/// The `peerStream` and `currentPeerCount` members required by
/// ``TopologyRuntime`` are intentionally inert placeholders in this phase:
/// the existing `runCoordinationLoop` is the sole consumer of
/// `transport.peers`, and fanning the stream out here would starve that loop
/// of events. These members will be populated when ``PeerClock`` migrates
/// full peer-forwarding into the runtime, tracked as a follow-up to the
/// v0.4.0 dual-topology plan.
internal final class MeshRuntime: TopologyRuntime, @unchecked Sendable {
    let transport: any Transport
    let peerStream: AsyncStream<[Peer]>
    let commandStream: AsyncStream<(PeerID, Command)>

    private let peerContinuation: AsyncStream<[Peer]>.Continuation
    private let commandContinuation: AsyncStream<(PeerID, Command)>.Continuation

    init(transport: any Transport) {
        self.transport = transport

        var pc: AsyncStream<[Peer]>.Continuation!
        self.peerStream = AsyncStream { pc = $0 }
        self.peerContinuation = pc

        var cc: AsyncStream<(PeerID, Command)>.Continuation!
        self.commandStream = AsyncStream { cc = $0 }
        self.commandContinuation = cc
    }

    func start() async throws {
        try await transport.start()
    }

    func stop() async {
        await transport.stop()
        peerContinuation.finish()
        commandContinuation.finish()
    }

    /// Placeholder — always `0` in Phase 2. See type-level doc comment.
    var currentPeerCount: Int {
        get async { 0 }
    }
}
