import Foundation
import os.signpost

private let topologySignposter = OSSignposter(subsystem: "net.hakaru.PeerClock", category: "Topology")

/// Auto-topology runtime. Starts as `MeshRuntime`; observes peer count via
/// `MeshRuntime.subscribePeers()`. When the `AutoHeuristic` threshold is
/// crossed and holds for `settleWindow`, emits a `TopologyTransition` on
/// `transitionEvents`. `PeerClock` subscribes and orchestrates the physical
/// swap by calling `performTransition()` followed by its own
/// `restartServices(transport:)` against the new star transport.
///
/// No reverse transition: once `.star`, stays `.star` for the lifetime of
/// this instance. Callers that want a fresh mesh start must stop and create
/// a new `PeerClock(topology: .mesh)`.
internal final class AutoRuntime: TopologyRuntime, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case mesh, star }

    let peerStream: AsyncStream<[Peer]>
    let commandStream: AsyncStream<(PeerID, Command)>
    let connectionEvents: AsyncStream<ConnectionEvent>
    let transitionEvents: AsyncStream<TopologyTransition>

    private let localPeerID: PeerID
    private let heuristic: AutoHeuristic
    private let configuration: Configuration
    private let settleWindow: Duration
    private let lock = NSLock()

    private var active: (any TopologyRuntime)?
    private var _mode: Mode = .mesh
    private var settleTask: Task<Void, Never>?
    /// Observes the inner `MeshRuntime.subscribePeers()` stream to drive
    /// `onPeerCount`. Torn down on transition / stop.
    private var peerObserverTask: Task<Void, Never>?
    /// Forwards `active.connectionEvents` into our own continuation. Re-spawned
    /// on `performTransition()` so events from the new inner runtime surface.
    private var connectionEventForwardTask: Task<Void, Never>?
    private var peerContinuation: AsyncStream<[Peer]>.Continuation
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation
    private var connectionEventsContinuation: AsyncStream<ConnectionEvent>.Continuation
    internal var transitionEventsContinuation: AsyncStream<TopologyTransition>.Continuation

    init(
        localPeerID: PeerID,
        heuristic: AutoHeuristic,
        configuration: Configuration,
        settleWindow: Duration = .seconds(3)
    ) {
        self.localPeerID = localPeerID
        self.heuristic = heuristic
        self.configuration = configuration
        self.settleWindow = settleWindow

        var pc: AsyncStream<[Peer]>.Continuation!
        self.peerStream = AsyncStream { pc = $0 }
        self.peerContinuation = pc

        var cc: AsyncStream<(PeerID, Command)>.Continuation!
        self.commandStream = AsyncStream { cc = $0 }
        self.commandContinuation = cc

        var ec: AsyncStream<ConnectionEvent>.Continuation!
        self.connectionEvents = AsyncStream { ec = $0 }
        self.connectionEventsContinuation = ec

        var te: AsyncStream<TopologyTransition>.Continuation!
        self.transitionEvents = AsyncStream { te = $0 }
        self.transitionEventsContinuation = te
    }

    var transport: any Transport {
        lock.withLock {
            guard let active else {
                preconditionFailure("AutoRuntime.transport accessed before start()")
            }
            return active.transport
        }
    }

    func start() async throws {
        let mesh = MeshRuntime(transport: WiFiTransport(localPeerID: localPeerID, configuration: configuration))
        try await mesh.start()
        lock.withLock {
            self.active = mesh
            self._mode = .mesh
        }
        startPeerObserver(from: mesh)
        spawnConnectionEventForwarder(from: mesh)
    }

    /// Subscribe to the inner `MeshRuntime.subscribePeers()` stream and
    /// funnel each peer-set snapshot into `onPeerCountObserved(_:)`.
    private func startPeerObserver(from mesh: MeshRuntime) {
        let stream = mesh.subscribePeers()
        let task = Task { [weak self] in
            for await peers in stream {
                if Task.isCancelled { break }
                await self?.onPeerCountObserved(peers.count)
            }
        }
        lock.withLock { self.peerObserverTask = task }
    }

    private func onPeerCountObserved(_ count: Int) async {
        onPeerCount(count)
    }

    /// (Re-)subscribe to the active inner runtime's `connectionEvents` stream.
    /// Spawns the new forwarder first, then atomically swaps-and-cancels the
    /// prior one under the lock — shrinks the handoff loss window to just the
    /// time the two subscribers co-exist.
    private func spawnConnectionEventForwarder(from runtime: any TopologyRuntime) {
        let cont = connectionEventsContinuation
        let task = Task {
            for await event in runtime.connectionEvents {
                cont.yield(event)
            }
        }
        let prior = lock.withLock { () -> Task<Void, Never>? in
            let p = connectionEventForwardTask
            self.connectionEventForwardTask = task
            return p
        }
        prior?.cancel()
    }

    func stop() async {
        let (current, settle, forward, peerObs) = lock.withLock { () -> ((any TopologyRuntime)?, Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            let s = settleTask; settleTask = nil
            let a = active; active = nil
            let f = connectionEventForwardTask; connectionEventForwardTask = nil
            let po = peerObserverTask; peerObserverTask = nil
            return (a, s, f, po)
        }
        peerObs?.cancel()
        settle?.cancel()
        forward?.cancel()
        await current?.stop()
        peerContinuation.finish()
        commandContinuation.finish()
        connectionEventsContinuation.finish()
        transitionEventsContinuation.finish()
    }

    var currentPeerCount: Int {
        get async {
            if let active = lock.withLock({ self.active }) {
                return await active.currentPeerCount
            }
            return 0
        }
    }

    var mode: Mode { lock.withLock { _mode } }

    /// Drive a peer-count observation and (conditionally) begin the settle
    /// window. On timeout the settle task emits a `TopologyTransition` event
    /// rather than performing the swap — the caller (`PeerClock`) is
    /// responsible for invoking `performTransition()`.
    private func onPeerCount(_ count: Int) {
        lock.withLock {
            guard case .peerCountThreshold(let n) = heuristic else { return }
            guard _mode == .mesh else { return }
            if count >= n {
                guard settleTask == nil else { return }
                settleTask = Task { [weak self] in
                    try? await Task.sleep(for: self?.settleWindow ?? .seconds(3))
                    if Task.isCancelled { return }
                    await self?.announceTransitionReady()
                }
            } else {
                settleTask?.cancel()
                settleTask = nil
            }
        }
    }

    /// Emit a `TopologyTransition(.meshToStar)` event iff we're still in
    /// `.mesh`. Does not mutate `_mode` or touch the inner runtime.
    private func announceTransitionReady() async {
        let readyToEmit = lock.withLock { _mode == .mesh }
        guard readyToEmit else { return }
        transitionEventsContinuation.yield(TopologyTransition(kind: .meshToStar))
    }

    /// Perform the physical mesh → star swap. Called explicitly by
    /// `PeerClock` after it has drained downstream services. Idempotent:
    /// a no-op if already in `.star`.
    ///
    /// Rollback-safe: star is started BEFORE mesh is stopped. If
    /// `star.start()` throws, mesh keeps serving traffic and the service
    /// layer stays bound to a live transport.
    internal func performTransition() async throws {
        let old: (any TopologyRuntime)? = lock.withLock {
            guard _mode == .mesh else { return nil }
            return active
        }
        guard let old else { return }

        let signpostID = topologySignposter.makeSignpostID()
        let interval = topologySignposter.beginInterval("mesh→star", id: signpostID)
        defer { topologySignposter.endInterval("mesh→star", interval) }

        // Start star first. If this throws, mesh is still alive — caller
        // sees the error, bails out, and everything downstream keeps working.
        // Mesh (`_peerclock._udp`) and star (`_peerclockstar._tcp`) advertise
        // on distinct Bonjour service types, so they don't compete.
        let star = StarRuntime(localPeerID: localPeerID, role: .auto, configuration: configuration)
        try await star.start()

        // Star is up; now tear down the mesh peer observer and the mesh runtime.
        let priorPeerObs = lock.withLock { () -> Task<Void, Never>? in
            let p = peerObserverTask; peerObserverTask = nil
            return p
        }
        priorPeerObs?.cancel()
        await old.stop()

        lock.withLock {
            self.active = star
            self._mode = .star
            self.settleTask = nil
        }
        // Re-subscribe the connectionEvents forwarder to the new runtime.
        spawnConnectionEventForwarder(from: star)
    }

    #if DEBUG
    /// Test-only: observe the current mode.
    internal var testHook_currentMode: Mode { mode }

    /// Test-only: simulate `count` discovered peers to exercise the heuristic.
    /// Drives the decision logic directly — same entry point as the real
    /// `mesh.subscribePeers()` observer.
    ///
    /// Also cancels the real peer-observer task so WiFi peer-set deliveries
    /// (which arrive as count=0 in a test environment with no real peers)
    /// cannot race against and cancel the injected settle window.
    internal func testHook_injectDiscoveredPeers(count: Int) {
        let obs = lock.withLock { () -> Task<Void, Never>? in
            let t = peerObserverTask
            peerObserverTask = nil
            return t
        }
        obs?.cancel()
        onPeerCount(count)
    }

    /// Test-only: synchronously await any pending settle window before
    /// checking mode. Allows tests to avoid `Task.sleep` races.
    internal func testHook_waitForSettleWindow() async {
        let task = lock.withLock { settleTask }
        await task?.value
    }
    #endif
}
