# Phase 2b: EventScheduler Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock に同期済み時刻ベースの精密イベント発火 API (`schedule(atSyncedTime:)`) を追加し、複数ピアでアクションを同時に発火できるようにする。

**Architecture:** `EventScheduler` actor が `[UUID: ScheduledEvent]` を管理。1 イベント = 1 Task で待機し、`tryFire` を actor 内 atomic に実行することで cancel/fire race を防ぐ。`Sleeper` プロトコル抽象化により、本番は `Task.sleep`、ユニットテストは `MockSleeper.advance(by:)` で決定論的に検証できる。`DriftMonitor` を拡張して `jumps: AsyncStream<JumpEvent>` を公開し、`PeerClock` が EventScheduler に橋渡しすることで再照準なしのジャンプ警告を実現する。

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, Foundation, os.log

**Spec reference:** `docs/superpowers/specs/2026-04-07-peerclock-v2-design.md` (Phase 2b 節)

---

## File Structure

**Create:**
- `Sources/PeerClock/EventScheduler/Sleeper.swift` — `Sleeper` protocol + `RealSleeper` + `MockSleeper`
- `Sources/PeerClock/EventScheduler/SchedulerTypes.swift` — `ScheduledEventState`, `SchedulerEvent`, `ScheduledEventHandle`
- `Sources/PeerClock/EventScheduler/EventScheduler.swift` — actor 本体
- `Tests/PeerClockTests/SleeperTests.swift`
- `Tests/PeerClockTests/EventSchedulerTests.swift`
- `Tests/PeerClockTests/EventSchedulerIntegrationTests.swift`

**Modify:**
- `Sources/PeerClock/ClockSync/DriftMonitor.swift` — `JumpEvent` 型 + `jumps: AsyncStream<JumpEvent>` 追加
- `Sources/PeerClock/PeerClock.swift` — EventScheduler 配線、`schedule(atSyncedTime:)` 公開、`schedulerEvents` 公開、DriftMonitor からの jump 橋渡し
- `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift` — 「3秒後に同期発火」ボタンのハンドラ
- `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift` — ボタン UI

---

## Task 1: DriftMonitor jump stream

**Files:**
- Modify: `Sources/PeerClock/ClockSync/DriftMonitor.swift`
- Modify: `Tests/PeerClockTests/DriftMonitorTests.swift`

- [ ] **Step 1: DriftMonitor を拡張**

`Sources/PeerClock/ClockSync/DriftMonitor.swift` を以下に置き換える:

```swift
import Foundation

public enum DriftResult: Sendable, Equatable {
    case normal
    case jumpDetected
}

/// クロックジャンプ検知時に流すイベント。
public struct JumpEvent: Sendable, Equatable {
    public let oldOffsetNs: Int64
    public let newOffsetNs: Int64

    public init(oldOffsetNs: Int64, newOffsetNs: Int64) {
        self.oldOffsetNs = oldOffsetNs
        self.newOffsetNs = newOffsetNs
    }
}

public final class DriftMonitor: @unchecked Sendable {
    private let jumpThresholdNs: Double
    private let lock = NSLock()
    private var lastOffset: Double?

    private let (stream, continuation) = AsyncStream<JumpEvent>.makeStream()
    public var jumps: AsyncStream<JumpEvent> { stream }

    public init(jumpThresholdNs: Double = 10_000_000) {
        self.jumpThresholdNs = jumpThresholdNs
    }

    @discardableResult
    public func recordOffset(_ offsetNs: Double) -> DriftResult {
        lock.lock()
        let previous = lastOffset
        lastOffset = offsetNs
        lock.unlock()

        guard let previous else {
            return .normal
        }

        let diff = abs(offsetNs - previous)
        if diff > jumpThresholdNs {
            continuation.yield(JumpEvent(
                oldOffsetNs: Int64(previous),
                newOffsetNs: Int64(offsetNs)
            ))
            return .jumpDetected
        }
        return .normal
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastOffset = nil
    }

    public func shutdown() {
        continuation.finish()
    }
}
```

- [ ] **Step 2: 既存テストに jump stream の検証を追加**

`Tests/PeerClockTests/DriftMonitorTests.swift` を読み、テストスイートの末尾に以下を追加:

```swift
    @Test("Jump stream emits old and new offset")
    func jumpStream() async throws {
        let monitor = DriftMonitor(jumpThresholdNs: 5_000_000)

        let collector = Task { () -> JumpEvent? in
            for await event in monitor.jumps {
                return event
            }
            return nil
        }

        _ = monitor.recordOffset(1_000_000)
        _ = monitor.recordOffset(20_000_000) // jump

        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.shutdown()
        let event = await collector.value
        #expect(event != nil)
        #expect(event?.oldOffsetNs == 1_000_000)
        #expect(event?.newOffsetNs == 20_000_000)
    }

    @Test("Normal updates do not emit jump events")
    func normalNoJump() async throws {
        let monitor = DriftMonitor(jumpThresholdNs: 100_000_000)

        var receivedAny = false
        let collector = Task {
            for await _ in monitor.jumps {
                receivedAny = true
                break
            }
        }

        _ = monitor.recordOffset(1_000_000)
        _ = monitor.recordOffset(2_000_000) // diff well under threshold

        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.shutdown()
        collector.cancel()
        #expect(receivedAny == false)
    }
```

- [ ] **Step 3: ビルド & テスト**

```bash
cd /Volumes/Dev/DEVELOP/PeerClock
swift build 2>&1 | tail -10
swift test --filter DriftMonitorTests 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: 全 56 テスト + 新規 2 テスト = 58 通過

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/ClockSync/DriftMonitor.swift Tests/PeerClockTests/DriftMonitorTests.swift
git commit -m "feat(drift): expose jumps AsyncStream with old/new offsets"
```

---

## Task 2: Sleeper protocol + Real/Mock implementations

**Files:**
- Create: `Sources/PeerClock/EventScheduler/Sleeper.swift`
- Create: `Tests/PeerClockTests/SleeperTests.swift`

- [ ] **Step 1: Sleeper.swift を作る**

```swift
// Sources/PeerClock/EventScheduler/Sleeper.swift
import Foundation

/// 抽象化された非同期スリープ。EventScheduler のテストでは `MockSleeper` を
/// 注入して仮想時刻で `advance(by:)` し、本番では `RealSleeper` で
/// `Task.sleep` を呼ぶ。
public protocol Sleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

/// 本番実装。`Task.sleep(nanoseconds:)` を呼ぶだけ。
public struct RealSleeper: Sleeper {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// テスト実装。
///
/// `sleep(nanoseconds:)` は continuation を waiter キューに enqueue し、
/// 仮想時刻を `advance(by:)` で進めると満期に達した waiter を resume する。
/// `cancel()` (Task キャンセル) でも resume するため、cancel/fire race の
/// テストが書ける。
public actor MockSleeper: Sleeper {
    private var virtualNow: UInt64 = 0
    private struct Waiter {
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
        let id: UUID
    }
    private var waiters: [Waiter] = []

    public init() {}

    public nonisolated func sleep(nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Task { await self.enqueue(nanoseconds: nanoseconds, cont: cont) }
            }
        } onCancel: {
            // Task is cancelled — best-effort wake. The actor cleanup happens
            // on next advance() since we cannot await from a sync handler.
            Task { await self.cancelAll() }
        }
    }

    private func enqueue(nanoseconds: UInt64, cont: CheckedContinuation<Void, Error>) {
        let waiter = Waiter(
            deadline: virtualNow &+ nanoseconds,
            continuation: cont,
            id: UUID()
        )
        waiters.append(waiter)
    }

    /// Advance the virtual clock by `nanoseconds`. Resume any waiter whose
    /// deadline has passed (in deadline order).
    public func advance(by nanoseconds: UInt64) {
        virtualNow &+= nanoseconds
        let due = waiters.filter { $0.deadline <= virtualNow }.sorted { $0.deadline < $1.deadline }
        waiters.removeAll { w in due.contains { $0.id == w.id } }
        for w in due {
            w.continuation.resume()
        }
    }

    /// Cancel every pending waiter (used by Task cancellation handler and shutdown).
    public func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.continuation.resume(throwing: CancellationError())
        }
    }

    public func pendingCount() -> Int { waiters.count }
}
```

- [ ] **Step 2: SleeperTests.swift を作る**

```swift
// Tests/PeerClockTests/SleeperTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("Sleeper")
struct SleeperTests {

    @Test("RealSleeper waits at least the requested duration")
    func realSleeperWaits() async throws {
        let sleeper = RealSleeper()
        let start = ContinuousClock().now
        try await sleeper.sleep(nanoseconds: 50_000_000) // 50ms
        let elapsed = ContinuousClock().now - start
        // Allow some scheduler slack but require at least ~40ms
        #expect(elapsed >= .milliseconds(40))
    }

    @Test("MockSleeper resumes after advance reaches deadline")
    func mockResumes() async throws {
        let sleeper = MockSleeper()

        let task = Task {
            try await sleeper.sleep(nanoseconds: 100)
            return "fired"
        }

        // Give the task a moment to enqueue.
        try await Task.sleep(nanoseconds: 20_000_000)

        await sleeper.advance(by: 100)

        let result = try await task.value
        #expect(result == "fired")
    }

    @Test("MockSleeper does not resume before deadline")
    func mockNoEarlyResume() async throws {
        let sleeper = MockSleeper()
        var fired = false

        let task = Task {
            try? await sleeper.sleep(nanoseconds: 1_000)
            fired = true
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await sleeper.advance(by: 500) // not enough
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(fired == false)

        await sleeper.advance(by: 500) // now enough
        _ = await task.value
        #expect(fired == true)
    }

    @Test("MockSleeper resumes multiple waiters in deadline order")
    func mockOrder() async throws {
        let sleeper = MockSleeper()

        actor Order {
            var marks: [Int] = []
            func mark(_ n: Int) { marks.append(n) }
            func read() -> [Int] { marks }
        }
        let order = Order()

        let t1 = Task { try? await sleeper.sleep(nanoseconds: 200); await order.mark(2) }
        let t2 = Task { try? await sleeper.sleep(nanoseconds: 100); await order.mark(1) }
        let t3 = Task { try? await sleeper.sleep(nanoseconds: 300); await order.mark(3) }

        try await Task.sleep(nanoseconds: 30_000_000)
        await sleeper.advance(by: 300)

        _ = await t1.value
        _ = await t2.value
        _ = await t3.value

        #expect(await order.read() == [1, 2, 3])
    }

    @Test("MockSleeper cancelAll throws CancellationError to all waiters")
    func mockCancelAll() async throws {
        let sleeper = MockSleeper()

        let task = Task {
            do {
                try await sleeper.sleep(nanoseconds: 1_000)
                return "fired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other"
            }
        }

        try await Task.sleep(nanoseconds: 30_000_000)
        await sleeper.cancelAll()

        let result = await task.value
        #expect(result == "cancelled")
    }
}
```

- [ ] **Step 3: ビルド & テスト**

```bash
swift build 2>&1 | tail -10
swift test --filter SleeperTests 2>&1 | tail -15
swift test 2>&1 | tail -5
```

Expected: 5 SleeperTests passed, 全体 63 通過

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/EventScheduler/Sleeper.swift Tests/PeerClockTests/SleeperTests.swift
git commit -m "feat(scheduler): Sleeper protocol with Real and Mock implementations"
```

---

## Task 3: SchedulerTypes (state, event, handle)

**Files:**
- Create: `Sources/PeerClock/EventScheduler/SchedulerTypes.swift`

- [ ] **Step 1: SchedulerTypes.swift を作る**

```swift
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
```

- [ ] **Step 2: ビルド (EventScheduler 未定義でエラー — 次タスクで修正)**

```bash
swift build 2>&1 | tail -10
```

Expected: `Cannot find type 'EventScheduler' in scope` のエラーのみ。

- [ ] **Step 3: Commit (broken intentionally)**

```bash
git add Sources/PeerClock/EventScheduler/SchedulerTypes.swift
git commit -m "feat(scheduler): scheduler types (handle, state, event)

Build is intentionally broken until Task 4 introduces EventScheduler."
```

---

## Task 4: EventScheduler actor

**Files:**
- Create: `Sources/PeerClock/EventScheduler/EventScheduler.swift`
- Create: `Tests/PeerClockTests/EventSchedulerTests.swift`

- [ ] **Step 1: EventScheduler.swift を作る**

```swift
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
```

- [ ] **Step 2: EventSchedulerTests.swift を作る**

```swift
// Tests/PeerClockTests/EventSchedulerTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("EventScheduler")
struct EventSchedulerTests {

    /// Synchronous virtual clock for the `now: () -> UInt64` injection.
    final class VClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: UInt64 = 0
        func advance(_ dt: UInt64) {
            lock.lock(); defer { lock.unlock() }
            t &+= dt
        }
        func read() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return t
        }
    }

    actor Counter {
        var value = 0
        func increment() { value += 1 }
        func read() -> Int { value }
    }

    @Test("schedule fires action at deadline")
    func basicFire() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        let id = await scheduler.schedule(atSyncedTime: 1_000) {
            Task { await counter.increment() }
        }

        clock.advance(1_000)
        await sleeper.advance(by: 1_000)

        // Yield so the detached action and counter actor process.
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await counter.read() == 1)
        #expect(await scheduler.state(of: id) == .fired)
    }

    @Test("Past time fires immediately as .missed")
    func pastTimeMissed() async throws {
        let clock = VClock()
        clock.advance(1_000)
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: MockSleeper())
        let counter = Counter()

        let id = await scheduler.schedule(atSyncedTime: 500) {
            Task { await counter.increment() }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(await counter.read() == 1)
        #expect(await scheduler.state(of: id) == .missed)
    }

    @Test("cancel before deadline prevents fire")
    func cancelPrevents() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        let id = await scheduler.schedule(atSyncedTime: 1_000) {
            Task { await counter.increment() }
        }

        await scheduler.cancel(id)

        clock.advance(1_000)
        await sleeper.advance(by: 1_000)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await counter.read() == 0)
        #expect(await scheduler.state(of: id) == .cancelled)
    }

    @Test("Multiple events fire in deadline order")
    func ordering() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)

        actor Marks {
            var seq: [Int] = []
            func mark(_ n: Int) { seq.append(n) }
            func read() -> [Int] { seq }
        }
        let marks = Marks()

        _ = await scheduler.schedule(atSyncedTime: 300) {
            Task { await marks.mark(3) }
        }
        _ = await scheduler.schedule(atSyncedTime: 100) {
            Task { await marks.mark(1) }
        }
        _ = await scheduler.schedule(atSyncedTime: 200) {
            Task { await marks.mark(2) }
        }

        clock.advance(300)
        await sleeper.advance(by: 300)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await marks.read() == [1, 2, 3])
    }

    @Test("Late wakeup beyond tolerance is reported as .missed")
    func lateWakeupMissed() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(
            now: { clock.read() },
            sleeper: sleeper,
            toleranceNs: 5_000_000  // 5ms tolerance
        )
        let counter = Counter()

        let id = await scheduler.schedule(atSyncedTime: 100_000_000) { // 100ms
            Task { await counter.increment() }
        }

        // Sleeper releases at 100ms, but we advance the clock by 200ms first
        // — simulating a late OS wakeup.
        clock.advance(200_000_000)
        await sleeper.advance(by: 100_000_000)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await counter.read() == 1)
        #expect(await scheduler.state(of: id) == .missed)
    }

    @Test("handleJump emits driftWarning for pending events")
    func driftWarning() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)

        let id = await scheduler.schedule(atSyncedTime: 1_000_000_000) {} // 1s ahead

        let collector = Task { () -> SchedulerEvent? in
            for await ev in scheduler.schedulerEvents {
                return ev
            }
            return nil
        }

        await scheduler.handleJump(oldOffsetNs: 1_000_000, newOffsetNs: 20_000_000)

        try await Task.sleep(nanoseconds: 50_000_000)
        collector.cancel()
        let event = await collector.value
        guard case .driftWarning(let evID, let oldNs, let newNs) = event else {
            Issue.record("Expected driftWarning")
            return
        }
        #expect(evID == id)
        #expect(oldNs == 1_000_000)
        #expect(newNs == 20_000_000)
    }

    @Test("shutdown cancels all pending events")
    func shutdownCancels() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        let id1 = await scheduler.schedule(atSyncedTime: 1_000) {
            Task { await counter.increment() }
        }
        let id2 = await scheduler.schedule(atSyncedTime: 2_000) {
            Task { await counter.increment() }
        }

        await scheduler.shutdown()

        clock.advance(2_000)
        await sleeper.advance(by: 2_000)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await counter.read() == 0)
        #expect(await scheduler.state(of: id1) == .cancelled)
        #expect(await scheduler.state(of: id2) == .cancelled)
    }
}
```

- [ ] **Step 3: ビルド & テスト**

```bash
swift build 2>&1 | tail -15
swift test --filter EventSchedulerTests 2>&1 | tail -20
swift test 2>&1 | tail -5
```

Expected: 7 EventSchedulerTests passed, 全体 70 通過

If timing-related flake occurs, increase the post-advance Task.sleep yields (50ms → 100ms). Don't change actor design.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/EventScheduler/EventScheduler.swift Tests/PeerClockTests/EventSchedulerTests.swift
git commit -m "feat(scheduler): EventScheduler actor with virtual-clock tests"
```

---

## Task 5: PeerClock facade integration

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`
- Create: `Tests/PeerClockTests/EventSchedulerIntegrationTests.swift`

- [ ] **Step 1: Read PeerClock.swift fully**

Read `Sources/PeerClock/PeerClock.swift` so you understand existing structure, lock pattern, start/stop sequencing, and the syncStateForwardTask that already calls `dm.recordOffset`.

- [ ] **Step 2: Add EventScheduler to PeerClock**

Add private vars (after the existing component vars):

```swift
    private var eventScheduler: EventScheduler?
    private var driftJumpRoutingTask: Task<Void, Never>?
```

- [ ] **Step 3: Construct EventScheduler in start()**

In the existing `lock.withLock` block where other components are created (around the `commandRouter` setup), add:

```swift
            // EventScheduler — uses self.now (synced) as time base, real Task.sleep
            let scheduler = EventScheduler(
                now: { [weak self] in self?.now ?? 0 },
                sleeper: RealSleeper()
            )
            self.eventScheduler = scheduler
```

(`self.now` is the existing computed property that returns `mach_continuous_time + offset` ナノ秒.)

- [ ] **Step 4: Forward DriftMonitor jumps to EventScheduler**

After `tr.start()` and after the `syncStateForwardTask` is launched, also launch a routing task. Add inside `start()`:

```swift
        // Forward drift jumps to the scheduler so it can warn pending events.
        let driftJumpTask = Task {
            for await jump in dm.jumps {
                await scheduler.handleJump(
                    oldOffsetNs: jump.oldOffsetNs,
                    newOffsetNs: jump.newOffsetNs
                )
            }
        }
        lock.withLock { self.driftJumpRoutingTask = driftJumpTask }
```

(`dm` here is the local var already set up earlier in `start()` for the syncStateForwardTask. If the variable name differs, use whatever the existing code calls the DriftMonitor.)

- [ ] **Step 5: Add public schedule API**

After the existing `// MARK: - Status API` block, add:

```swift
    // MARK: - EventScheduler API

    /// Schedule an action to fire at a synced time. Returns a handle for
    /// cancellation and state inspection.
    /// - parameter atSyncedTime: nanoseconds in the same time base as `clock.now`
    public func schedule(
        atSyncedTime: UInt64,
        _ action: @Sendable @escaping () -> Void
    ) async -> ScheduledEventHandle {
        guard let scheduler = lock.withLock({ eventScheduler }) else {
            // Scheduler not started — return a dead handle.
            return ScheduledEventHandle(id: UUID(), scheduler: EventScheduler(
                now: { 0 },
                sleeper: RealSleeper()
            ))
        }
        let id = await scheduler.schedule(atSyncedTime: atSyncedTime, action)
        return ScheduledEventHandle(id: id, scheduler: scheduler)
    }

    /// Stream of scheduler notification events (e.g. clock drift warnings).
    public var schedulerEvents: AsyncStream<SchedulerEvent> {
        lock.withLock { eventScheduler }?.schedulerEvents ?? AsyncStream { $0.finish() }
    }
```

- [ ] **Step 6: Shutdown in stop()**

In the existing `stop()` method's lock collection block, add:

```swift
        let djTask = driftJumpRoutingTask; driftJumpRoutingTask = nil
        let scheduler = eventScheduler; eventScheduler = nil
```

After the lock block, add:

```swift
        djTask?.cancel()
        await scheduler?.shutdown()
```

- [ ] **Step 7: Build**

```bash
swift build 2>&1 | tail -20
```

Expected: clean build. Common issues: `dm` variable name, weak self capture in closures, the dead-handle fallback may need adjustment if EventScheduler init signature differs.

- [ ] **Step 8: Create EventSchedulerIntegrationTests.swift**

```swift
// Tests/PeerClockTests/EventSchedulerIntegrationTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — EventScheduler integration")
struct EventSchedulerIntegrationTests {

    actor Box {
        var fired = false
        func mark() { fired = true }
        func read() -> Bool { fired }
    }

    @Test("schedule via facade fires after real wait")
    func facadeFires() async throws {
        let network = MockNetwork()
        let clock = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await clock.start()

        let box = Box()
        let when = clock.now + 80_000_000 // 80ms ahead
        let handle = await clock.schedule(atSyncedTime: when) {
            Task { await box.mark() }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await box.read() == true)
        #expect(await handle.state() == .fired)

        await clock.stop()
    }

    @Test("schedule cancel via handle prevents fire")
    func cancelViaHandle() async throws {
        let network = MockNetwork()
        let clock = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await clock.start()

        let box = Box()
        let when = clock.now + 200_000_000 // 200ms ahead
        let handle = await clock.schedule(atSyncedTime: when) {
            Task { await box.mark() }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await handle.cancel()

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await box.read() == false)
        #expect(await handle.state() == .cancelled)

        await clock.stop()
    }

    @Test("Two peers fire near-simultaneously at the same synced time")
    func twoPeersFireTogether() async throws {
        let network = MockNetwork()
        let a = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await a.start()
        try await b.start()

        // Wait for sync to converge a bit.
        try await Task.sleep(nanoseconds: 800_000_000)

        actor Times {
            var marks: [(String, UInt64)] = []
            func add(_ tag: String, _ t: UInt64) { marks.append((tag, t)) }
            func read() -> [(String, UInt64)] { marks }
        }
        let times = Times()

        // Both peers schedule at A's now + 200ms. (They share the same time base
        // up to clock-sync error.)
        let target = a.now + 200_000_000
        _ = await a.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await times.add("a", t) }
        }
        _ = await b.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await times.add("b", t) }
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        let marks = await times.read()
        #expect(marks.count == 2)
        if marks.count == 2 {
            let dt = Int64(marks[0].1) - Int64(marks[1].1)
            // Expect within ~20ms (clock sync + scheduler jitter, plenty of slack)
            #expect(abs(dt) < 20_000_000)
        }

        await a.stop()
        await b.stop()
    }
}
```

- [ ] **Step 9: Run integration tests**

```bash
swift test --filter EventSchedulerIntegrationTests 2>&1 | tail -20
swift test 2>&1 | tail -5
```

Expected: 3 integration tests passed, 全体 73 通過

If `twoPeersFireTogether` is flaky, increase the convergence sleep (800ms → 1500ms) or relax the dt tolerance (20ms → 30ms).

- [ ] **Step 10: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift Tests/PeerClockTests/EventSchedulerIntegrationTests.swift
git commit -m "feat(facade): wire EventScheduler into PeerClock"
```

---

## Task 6: Demo app schedule button

**Files:**
- Modify: `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift`
- Modify: `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift`

- [ ] **Step 1: Add ViewModel state and method**

Read `PeerClockViewModel.swift` first. Add property:

```swift
    private(set) var lastScheduledFireLog: String = "-"
    private var scheduleHandle: ScheduledEventHandle?
```

Add method (next to `broadcastPing`):

```swift
    func scheduleBeepIn3Seconds() async {
        guard let clock else { return }
        let target = clock.now + 3_000_000_000  // 3 seconds ahead
        appendLog("Scheduling fire at +3s (synced)")
        let handle = await clock.schedule(atSyncedTime: target) { [weak self] in
            Task { @MainActor in
                self?.lastScheduledFireLog = "🔔 fired at \(ISO8601DateFormatter().string(from: Date()))"
                self?.appendLog("🔔 Scheduled event fired")
            }
        }
        scheduleHandle = handle
    }

    func cancelScheduledBeep() async {
        await scheduleHandle?.cancel()
        scheduleHandle = nil
        appendLog("Cancelled scheduled event")
    }
```

In `stop()`, also clear the handle:

```swift
        scheduleHandle = nil
        lastScheduledFireLog = "-"
```

- [ ] **Step 2: Add buttons to ContentView**

Read `ContentView.swift` first. Add a new section after the existing Commands section:

```swift
            VStack(alignment: .leading, spacing: 8) {
                Text("Scheduled Events")
                    .font(.headline)
                HStack {
                    Button("Schedule +3s") {
                        Task { await viewModel.scheduleBeepIn3Seconds() }
                    }
                    .buttonStyle(.bordered)

                    Button("Cancel") {
                        Task { await viewModel.cancelScheduledBeep() }
                    }
                    .buttonStyle(.bordered)
                }
                Text(viewModel.lastScheduledFireLog)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
```

- [ ] **Step 3: Build the demo app**

```bash
xcodebuild -project /Volumes/Dev/DEVELOP/PeerClock/Examples/PeerClockDemo/PeerClockDemo.xcodeproj -scheme PeerClockDemo -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
git commit -m "feat(demo): add Schedule +3s button to demo app"
```

---

## Task 7: Simulator E2E verification

**Files:** No code changes. Manual verification.

- [ ] **Step 1: Reinstall both simulators**

```bash
APP="/Users/hakaru/Library/Developer/Xcode/DerivedData/PeerClockDemo-drqkujgbdgpwfdblvgcnuecbddks/Build/Products/Debug-iphonesimulator/PeerClockDemo.app"
xcrun simctl terminate AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl terminate 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl install AF61223F-58C5-48A3-BF21-54F942BA3C32 "$APP"
xcrun simctl install 981BFB44-64A5-476D-88B2-9B34CF8D8762 "$APP"
xcrun simctl launch AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo
xcrun simctl launch 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo
```

- [ ] **Step 2: Manual checklist**

User verifies:
1. ✅ Both apps Start successfully and discover each other
2. ✅ Tap "Schedule +3s" on iPhone 17 → after 3s, the log shows `🔔 Scheduled event fired` and the caption shows the fire timestamp
3. ✅ Tap "Schedule +3s" then "Cancel" within 1s → no fire happens, log shows `Cancelled scheduled event`
4. ✅ Tap "Schedule +3s" on BOTH apps within 1s of each other → both log fire events at near-identical wall-clock time (within ~20ms ideally)
5. ✅ Existing features still work (Broadcast Ping, status display, connection state)

Receive screenshot from user and debug if needed.

- [ ] **Step 3: Tag completion**

```bash
git tag -a phase-2b-complete -m "Phase 2b: EventScheduler complete"
```

(do not push)

---

## Self-Review Checklist

- [x] Spec coverage: each Phase 2b spec section maps to a task
  - DriftMonitor jump stream → Task 1
  - Sleeper protocol → Task 2
  - SchedulerTypes (handle, state, event) → Task 3
  - EventScheduler actor (cancel/fire race, .missed/.fired, drift handling) → Task 4
  - PeerClock facade integration → Task 5
  - Demo app + manual E2E → Tasks 6-7
- [x] No placeholders. Each code step contains actual code.
- [x] Type consistency: `ScheduledEventHandle`, `ScheduledEventState (.pending/.fired/.cancelled/.missed)`, `SchedulerEvent.driftWarning`, `EventScheduler`, `Sleeper`, `RealSleeper`, `MockSleeper`, `JumpEvent` are used identically across tasks.
- [x] TDD: test files created alongside or before implementation files.
- [x] Frequent commits: 7 tasks × 1 commit each.

## Known Risks

1. **PeerClock.swift edits**: NSLock-based class. Calling actor methods inside `lock.withLock` blocks is unsafe (deadlock risk). Always release the lock before `await scheduler.something()`.
2. **Sleeper.swift MockSleeper continuation handling**: The `withTaskCancellationHandler { ... }` pattern with an actor enqueue is delicate. If `cancelAll` races with a fresh enqueue from a recently-resumed task, you may double-resume a continuation. Implementation should be defensive (use `removeAll` on the waiter list before resuming).
3. **Two-peer integration test (Task 5 Step 9)**: relies on real Task.sleep timing. Allow 800ms for sync convergence, 200ms scheduling lead, 500ms post-fire collection. Adjust upward if CI is slow.
4. **Demo app `[weak self]` in @Sendable closure**: SwiftUI ViewModels are `@MainActor`. Capturing `self` weakly inside `@Sendable` closure works but the captured method body must hop back to MainActor via `Task { @MainActor in ... }` (already shown in the plan).
5. **Dead-handle fallback in Task 5 Step 5**: creating a throwaway EventScheduler instance just to make the handle is awkward. Acceptable shim for the "scheduler not started" edge case (rare). If it causes issues, change `ScheduledEventHandle` to allow nil scheduler reference.
