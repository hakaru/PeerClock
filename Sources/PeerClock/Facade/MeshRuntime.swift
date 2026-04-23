import Foundation

/// Owns the mesh-topology transport lifecycle behind the ``PeerClock`` facade.
///
/// Phase 2 scope: transport lifecycle plus a peer-set fan-out. `CommandRouter`,
/// `NTPSyncEngine`, `HeartbeatMonitor`, `StatusRegistry`, and the legacy
/// peer-forwarding coordination loop remain owned by ``PeerClock`` itself and
/// are wired against `runtime.transport` after `start()`.
///
/// `subscribePeers()` / `peerStream` now return real `[Peer]` values derived
/// from `transport.peers`. Because `PeerStreamFanOut` is 1-to-N, the existing
/// `runCoordinationLoop` inside ``PeerClock`` (which still iterates
/// `transport.peers` directly) continues to receive events without starvation.
internal final class MeshRuntime: TopologyRuntime, @unchecked Sendable {
    let transport: any Transport
    let commandStream: AsyncStream<(PeerID, Command)>
    let connectionEvents: AsyncStream<ConnectionEvent>

    private let fanOut = PeerStreamFanOut<[Peer]>()
    private let commandContinuation: AsyncStream<(PeerID, Command)>.Continuation
    private let connectionEventsContinuation: AsyncStream<ConnectionEvent>.Continuation

    private let lock = NSLock()
    private var peerObserverTask: Task<Void, Never>?

    init(transport: any Transport) {
        self.transport = transport

        var cc: AsyncStream<(PeerID, Command)>.Continuation!
        self.commandStream = AsyncStream { cc = $0 }
        self.commandContinuation = cc

        // Mesh topology has no handshake, so this stream never yields.
        // It exists purely to satisfy the TopologyRuntime protocol
        // (AutoRuntime / PeerClock treat it uniformly).
        var ec: AsyncStream<ConnectionEvent>.Continuation!
        self.connectionEvents = AsyncStream { ec = $0 }
        self.connectionEventsContinuation = ec
    }

    func start() async throws {
        try await transport.start()

        // Observe transport peers and fan out to all subscribers.
        let peersStream = transport.peers
        let fanOut = self.fanOut
        let task = Task {
            for await peerSet in peersStream {
                if Task.isCancelled { break }
                let peers = peerSet.map { id in
                    Peer(
                        id: id,
                        name: id.description,
                        status: PeerStatus(
                            peerID: id,
                            connectionState: .connected,
                            deviceInfo: DeviceInfo(
                                name: id.description,
                                platform: .iOS,
                                storageAvailable: 0
                            ),
                            generation: 0
                        )
                    )
                }
                fanOut.publish(peers)
            }
        }
        lock.withLock { self.peerObserverTask = task }
    }

    func stop() async {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let t = peerObserverTask
            peerObserverTask = nil
            return t
        }
        task?.cancel()

        await transport.stop()
        fanOut.finish()
        commandContinuation.finish()
        connectionEventsContinuation.finish()
    }

    /// Subscribe to peer-set updates derived from `transport.peers`.
    /// Each subscriber receives the last-published snapshot (if any) on subscribe,
    /// then every subsequent update.
    func subscribePeers() -> AsyncStream<[Peer]> {
        fanOut.subscribe()
    }

    /// `TopologyRuntime` conformance — returns a fresh fan-out subscription.
    /// Prefer `subscribePeers()` in new code; kept as a property because the
    /// protocol requirement is a `var`.
    var peerStream: AsyncStream<[Peer]> {
        fanOut.subscribe()
    }

    /// Last peer-count observed from `transport.peers`. Returns 0 before any
    /// peer set has been published.
    var currentPeerCount: Int {
        get async { fanOut.lastValue?.count ?? 0 }
    }
}
