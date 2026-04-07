// Sources/PeerClock/EventScheduler/SchedulerTypes.swift
import Foundation

/// 予約イベントのライフサイクル状態。
public enum ScheduledEventState: Sendable, Equatable {
    /// 待機中。
    case pending
    /// 予定通り発火 (action 実行済み)。
    case fired
    /// キャンセル済み。これが action 不実行を示す唯一のターミナル状態。
    case cancelled
    /// 過去時刻指定または起床時遅延 tolerance 超過のため遅刻発火扱い
    /// (action は実行された)。
    case missed
}

/// EventScheduler から流れる通知イベント。
public enum SchedulerEvent: Sendable, Equatable {
    /// クロックジャンプ検知。eventID は予約中だったイベント。
    /// 再照準はしないため、アプリは事後にタイムスタンプ補正等の判断に使う。
    case driftWarning(eventID: UUID, oldOffsetNs: Int64, newOffsetNs: Int64)
}

/// アプリが予約後に保持するハンドル。
///
/// 内部は UUID と EventScheduler への弱参照のみ。循環参照を避けるため、
/// 実体 (action と Task) は EventScheduler 側が強参照する。
public struct ScheduledEventHandle: Sendable, Hashable {
    public let id: UUID
    private let scheduler: WeakSchedulerBox

    internal init(id: UUID, scheduler: EventScheduler) {
        self.id = id
        self.scheduler = WeakSchedulerBox(scheduler)
    }

    public func cancel() async {
        await scheduler.value?.cancel(id)
    }

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
