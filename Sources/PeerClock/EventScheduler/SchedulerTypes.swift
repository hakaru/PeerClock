// Sources/PeerClock/EventScheduler/SchedulerTypes.swift
import Foundation

/// Lifecycle state of a scheduled event.
public enum ScheduledEventState: Sendable, Equatable {
    /// Waiting to fire.
    case pending
    /// Fired on time (action executed).
    case fired
    /// Cancelled before firing (action was not executed).
    case cancelled
    /// Fired late due to past-time scheduling or wake-up delay (action was
    /// executed).
    case missed
}

/// Notification events emitted by the event scheduler.
public enum SchedulerEvent: Sendable, Equatable {
    /// A clock-drift jump was detected while an event was pending.
    case driftWarning(eventID: UUID, oldOffsetNs: Int64, newOffsetNs: Int64)
}

/// Handle returned after scheduling an event.
///
/// Holds a `UUID` and a weak reference to the scheduler.
public struct ScheduledEventHandle: Sendable, Hashable {
    /// Unique identifier for the scheduled event.
    public let id: UUID
    private let scheduler: WeakSchedulerBox

    internal init(id: UUID, scheduler: EventScheduler) {
        self.id = id
        self.scheduler = WeakSchedulerBox(scheduler)
    }

    /// Cancels this event.
    ///
    /// No-op if it has already fired or been cancelled.
    public func cancel() async {
        await scheduler.value?.cancel(id)
    }

    /// Returns the current state of this event.
    public func state() async -> ScheduledEventState {
        await scheduler.value?.state(of: id) ?? .cancelled
    }

    public static func == (lhs: ScheduledEventHandle, rhs: ScheduledEventHandle) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// `Sendable` な弱参照ボックス。actor 型は class なので weak 可能。
internal struct WeakSchedulerBox: Sendable {
    private final class Box: @unchecked Sendable {
        weak var value: EventScheduler?
        init(_ value: EventScheduler) { self.value = value }
    }
    private let box: Box
    init(_ scheduler: EventScheduler) { self.box = Box(scheduler) }
    var value: EventScheduler? { box.value }
}
