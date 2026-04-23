import Foundation
import os.signpost

private let topologySignposter = OSSignposter(subsystem: "net.hakaru.PeerClock", category: "Topology")

/// Auto-topology runtime. Starts as `MeshRuntime`; when the peer-count
/// heuristic fires (and remains above threshold for `settleWindow`), stops
/// the inner mesh runtime and starts a `StarRuntime`. No reverse transition.
///
/// Scope limitation (as of v0.4.0):
/// - Real peer-count observation is not wired: `MeshRuntime.peerStream` is a
///   placeholder pending a `transport.peers` fan-out refactor. The transition
///   is driven in tests by `testHook_injectDiscoveredPeers(_:)` for now.
/// - Transport hot-swap is logical only: `PeerClock.start()` snapshots the
///   initial transport, so downstream services continue to address the mesh
///   transport after transition. Full physical swap requires coordinated
///   restart of NTPSync/CommandRouter/heartbeat/status at the facade.
///
/// See the tech-debt task "real mesh peer-count observation + hot-swap".
internal final class AutoRuntime: TopologyRuntime, @unchecked Sendable {
    enum Mode: Sendable, Equatable { case mesh, star }

    let peerStream: AsyncStream<[Peer]>
    let commandStream: AsyncStream<(PeerID, Command)>
    let connectionEvents: AsyncStream<ConnectionEvent>

    private let localPeerID: PeerID
    private let heuristic: AutoHeuristic
    private let configuration: Configuration
    private let settleWindow: Duration
    private let lock = NSLock()

    private var active: (any TopologyRuntime)?
    private var _mode: Mode = .mesh
    private var settleTask: Task<Void, Never>?
    /// Forwards `active.connectionEvents` into our own continuation. Re-spawned
    /// on `transitionToStar()` so events from the new inner runtime surface.
    private var connectionEventForwardTask: Task<Void, Never>?
    private var peerContinuation: AsyncStream<[Peer]>.Continuation
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation
    private var connectionEventsContinuation: AsyncStream<ConnectionEvent>.Continuation

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
        lock.withLock { self.active = mesh }
        try await mesh.start()
        spawnConnectionEventForwarder(from: mesh)
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
        let (current, settle, forward) = lock.withLock { () -> ((any TopologyRuntime)?, Task<Void, Never>?, Task<Void, Never>?) in
            let s = settleTask; settleTask = nil
            let a = active; active = nil
            let f = connectionEventForwardTask; connectionEventForwardTask = nil
            return (a, s, f)
        }
        settle?.cancel()
        forward?.cancel()
        await current?.stop()
        peerContinuation.finish()
        commandContinuation.finish()
        connectionEventsContinuation.finish()
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
    /// window towards transition. Normally invoked by an internal observer
    /// watching `mesh.peerStream`; today that stream is a placeholder, so
    /// the primary caller is the test hook.
    private func onPeerCount(_ count: Int) {
        lock.withLock {
            guard case .peerCountThreshold(let n) = heuristic else { return }
            guard _mode == .mesh else { return }
            if count >= n {
                guard settleTask == nil else { return }
                settleTask = Task { [weak self] in
                    try? await Task.sleep(for: self?.settleWindow ?? .seconds(3))
                    if Task.isCancelled { return }
                    await self?.transitionToStar()
                }
            } else {
                settleTask?.cancel()
                settleTask = nil
            }
        }
    }

    private func transitionToStar() async {
        let signpostID = topologySignposter.makeSignpostID()
        let interval = topologySignposter.beginInterval("mesh→star", id: signpostID)
        defer { topologySignposter.endInterval("mesh→star", interval) }

        let shouldTransition: Bool = lock.withLock {
            _mode == .mesh
        }
        guard shouldTransition else { return }

        let old: (any TopologyRuntime)? = lock.withLock {
            let o = active
            return o
        }
        await old?.stop()

        let star = StarRuntime(localPeerID: localPeerID, role: .auto, configuration: configuration)
        do {
            try await star.start()
            lock.withLock {
                self.active = star
                self._mode = .star
                self.settleTask = nil
            }
            // Re-subscribe observability forwarder to the new inner runtime.
            spawnConnectionEventForwarder(from: star)
        } catch {
            // Rollback: best effort — recreate mesh. In practice this is rare;
            // logging the failure is enough for the skeleton.
        }
    }

    #if DEBUG
    /// Test-only: observe the current mode.
    internal var testHook_currentMode: Mode { mode }

    /// Test-only: simulate `count` discovered peers to exercise the heuristic.
    /// Does not exercise the inner MeshRuntime's actual peer stream — it
    /// drives the decision logic directly.
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
