import Foundation
import os.signpost

private let topologySignposter = OSSignposter(subsystem: "net.hakaru.PeerClock", category: "Topology")

/// Auto-topology runtime. Starts as `MeshRuntime`; when the peer-count
/// heuristic fires (and remains above threshold for `settleWindow`), emits a
/// `TopologyTransition(.meshToStar)` on `transitionEvents`. The physical swap
/// is no longer performed inline — `PeerClock` observes the event, drains
/// downstream services, then calls back into `performTransition()` to execute
/// the swap. No reverse transition.
///
/// Real peer-count observation is now wired through `MeshRuntime.subscribePeers()`
/// (Phase 1 fan-out). Tests may still inject counts synthetically via
/// `testHook_injectDiscoveredPeers(_:)`.
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
    /// Cancels any prior forwarder and spawns a new one.
    private func spawnConnectionEventForwarder(from runtime: any TopologyRuntime) {
        let prior = lock.withLock { () -> Task<Void, Never>? in
            let p = connectionEventForwardTask
            return p
        }
        prior?.cancel()
        let cont = connectionEventsContinuation
        let task = Task {
            for await event in runtime.connectionEvents {
                cont.yield(event)
            }
        }
        lock.withLock { self.connectionEventForwardTask = task }
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
    internal func performTransition() async throws {
        let old: (any TopologyRuntime)? = lock.withLock {
            guard _mode == .mesh else { return nil }
            return active
        }
        guard let old else { return }

        let signpostID = topologySignposter.makeSignpostID()
        let interval = topologySignposter.beginInterval("mesh→star", id: signpostID)
        defer { topologySignposter.endInterval("mesh→star", interval) }

        // Tear down the mesh peer observer and the mesh runtime itself.
        let priorPeerObs = lock.withLock { () -> Task<Void, Never>? in
            let p = peerObserverTask; peerObserverTask = nil
            return p
        }
        priorPeerObs?.cancel()
        await old.stop()

        let star = StarRuntime(localPeerID: localPeerID, role: .auto, configuration: configuration)
        try await star.start()
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
    internal func testHook_injectDiscoveredPeers(count: Int) {
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
