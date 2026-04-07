// Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift
import Foundation

/// Actor tracking per-peer heartbeat freshness and driving connection state
/// transitions. Time is injected via a closure so tests can advance a virtual
/// clock without waiting on real time.
public actor HeartbeatMonitor {

    public struct Event: Sendable, Equatable {
        public let peerID: PeerID
        public let state: ConnectionState

        public init(peerID: PeerID, state: ConnectionState) {
            self.peerID = peerID
            self.state = state
        }
    }

    // MARK: - Dependencies (immutable, isolation-free)

    public nonisolated let interval: TimeInterval
    public nonisolated let degradedAfter: TimeInterval
    public nonisolated let disconnectedAfter: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let broadcast: @Sendable () async throws -> Void

    // MARK: - State

    private var lastSeen: [PeerID: TimeInterval] = [:]
    private var peerState: [PeerID: ConnectionState] = [:]
    private var sendTask: Task<Void, Never>?
    private var evalTask: Task<Void, Never>?

    private let (stream, continuation) = AsyncStream<Event>.makeStream()
    public nonisolated var events: AsyncStream<Event> { stream }

    public init(
        interval: TimeInterval,
        degradedAfter: TimeInterval,
        disconnectedAfter: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        broadcast: @escaping @Sendable () async throws -> Void
    ) {
        self.interval = interval
        self.degradedAfter = degradedAfter
        self.disconnectedAfter = disconnectedAfter
        self.now = now
        self.broadcast = broadcast
    }

    // MARK: - Public API

    /// Starts both the periodic sender and the periodic evaluator. Real-time
    /// background loops — tests should NOT call this; they call `evaluate()` directly.
    public func start() {
        guard sendTask == nil else { return }
        let intervalNs = UInt64(interval * 1_000_000_000)
        let halfIntervalNs = intervalNs / 2

        sendTask = Task {
            while !Task.isCancelled {
                try? await self.broadcast()
                try? await Task.sleep(nanoseconds: intervalNs)
            }
        }
        evalTask = Task {
            while !Task.isCancelled {
                await self.evaluate()
                try? await Task.sleep(nanoseconds: halfIntervalNs)
            }
        }
    }

    public func stop() {
        sendTask?.cancel()
        evalTask?.cancel()
        sendTask = nil
        evalTask = nil
        continuation.finish()
    }

    /// Records an incoming heartbeat from a peer.
    public func heartbeatReceived(from peerID: PeerID) {
        lastSeen[peerID] = now()
        transition(peerID, to: .connected)
    }

    /// Called when a new peer connects (before any heartbeat). Starts tracking.
    public func peerJoined(_ peerID: PeerID) {
        lastSeen[peerID] = now()
        transition(peerID, to: .connected)
    }

    /// Called on explicit disconnect (peer dropped, transport error). Stops tracking.
    public func peerLeft(_ peerID: PeerID) {
        lastSeen.removeValue(forKey: peerID)
        peerState.removeValue(forKey: peerID)
        // Note: do not emit a final event here; callers can observe absence.
    }

    /// Runs one evaluation pass: updates each peer's state based on elapsed time.
    public func evaluate() {
        let current = now()
        for (peerID, seen) in lastSeen {
            let elapsed = current - seen
            let newState: ConnectionState
            if elapsed >= disconnectedAfter {
                newState = .disconnected
            } else if elapsed >= degradedAfter {
                newState = .degraded
            } else {
                newState = .connected
            }
            transition(peerID, to: newState)
        }
    }

    /// Current state for a peer (test introspection).
    public func currentState(of peerID: PeerID) -> ConnectionState? {
        peerState[peerID]
    }

    // MARK: - Internals

    private func transition(_ peerID: PeerID, to newState: ConnectionState) {
        if peerState[peerID] == newState { return }
        peerState[peerID] = newState
        continuation.yield(Event(peerID: peerID, state: newState))
    }
}
