// Sources/PeerClock/EventScheduler/EventScheduler.swift
import Foundation
import os

/// 同期済み時刻 (`now()`) で予約された action を発火する actor。
///
/// 設計:
/// - 1 イベント = 1 Task の構造。Task は Sleeper.sleep で待機する
/// - tryFire は actor isolated なので cancel/fire race が起きない
/// - action は detached Task で実行され、actor をブロックしない
/// - 起床時に当初予定より tolerance を超えていれば .missed として記録する
///   (action は実行する)
public actor EventScheduler {

    public typealias Action = @Sendable () -> Void

    // MARK: - Dependencies

    private let now: @Sendable () -> UInt64
    private let sleeper: Sleeper
    private let toleranceNs: UInt64
    private let logger: Logger

    // MARK: - State

    private struct ScheduledEvent {
        let id: UUID
        let atSyncedTime: UInt64
        let action: Action
        var task: Task<Void, Never>?
        var state: ScheduledEventState
    }

    private var events: [UUID: ScheduledEvent] = [:]

    private let (eventStream, eventContinuation) = AsyncStream<SchedulerEvent>.makeStream()
    public nonisolated var schedulerEvents: AsyncStream<SchedulerEvent> { eventStream }

    public init(
        now: @escaping @Sendable () -> UInt64,
        sleeper: Sleeper = RealSleeper(),
        toleranceNs: UInt64 = 10_000_000  // 10ms
    ) {
        self.now = now
        self.sleeper = sleeper
        self.toleranceNs = toleranceNs
        self.logger = Logger(subsystem: "net.hakaru.PeerClock", category: "EventScheduler")
    }

    // MARK: - Public API

    /// Schedule an action and return its UUID. The PeerClock facade wraps it
    /// into a `ScheduledEventHandle`.
    public func schedule(atSyncedTime: UInt64, _ action: @escaping Action) -> UUID {
        let id = UUID()
        var event = ScheduledEvent(
            id: id,
            atSyncedTime: atSyncedTime,
            action: action,
            task: nil,
            state: .pending
        )
        events[id] = event

        let delay = Int64(atSyncedTime) - Int64(now())
        if delay <= 0 {
            // 過去時刻 — 即座に missed として fire。
            tryFire(id, forceMissed: true)
            return id
        }

        let waitNs = UInt64(delay)
        let task = Task {
            try? await self.sleeper.sleep(nanoseconds: waitNs)
            await self.tryFire(id, forceMissed: false)
        }
        event.task = task
        events[id] = event
        return id
    }

    public func cancel(_ id: UUID) {
        guard var event = events[id], event.state == .pending else { return }
        event.state = .cancelled
        event.task?.cancel()
        events[id] = event
    }

    public func state(of id: UUID) -> ScheduledEventState {
        events[id]?.state ?? .cancelled
    }

    /// Forwarded by PeerClock when DriftMonitor reports a jump.
    public func handleJump(oldOffsetNs: Int64, newOffsetNs: Int64) {
        for (id, event) in events where event.state == .pending {
            logger.warning(
                "Drift jump during scheduled event \(id.uuidString): old=\(oldOffsetNs) new=\(newOffsetNs)"
            )
            eventContinuation.yield(.driftWarning(
                eventID: id,
                oldOffsetNs: oldOffsetNs,
                newOffsetNs: newOffsetNs
            ))
        }
    }

    /// Cancels all pending events. Called from PeerClock.stop().
    public func shutdown() {
        for (id, var event) in events where event.state == .pending {
            event.state = .cancelled
            event.task?.cancel()
            events[id] = event
        }
    }

    // MARK: - Internals

    /// Atomic transition from pending → fired/missed. The detached action
    /// only runs if the guard passes; this is the cancel/fire race fix.
    private func tryFire(_ id: UUID, forceMissed: Bool) {
        guard var event = events[id], event.state == .pending else { return }

        // Determine fired vs missed based on actual elapsed time.
        let lateness = Int64(now()) - Int64(event.atSyncedTime)
        if forceMissed || lateness > Int64(toleranceNs) {
            event.state = .missed
        } else {
            event.state = .fired
        }
        events[id] = event

        let action = event.action
        Task.detached {
            action()
        }
    }
}
