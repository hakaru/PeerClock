// Tests/PeerClockTests/EventSchedulerTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("EventScheduler")
struct EventSchedulerTests {

    /// Synchronous virtual clock for `now: () -> UInt64` injection.
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

        // Let the schedule task enqueue with the sleeper
        try await Task.sleep(nanoseconds: 50_000_000)

        clock.advance(1_000)
        await sleeper.advance(by: 1_000)

        // Yield so the detached action and counter actor process.
        try await Task.sleep(nanoseconds: 100_000_000)

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

        try await Task.sleep(nanoseconds: 100_000_000)
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

        try await Task.sleep(nanoseconds: 50_000_000)
        await scheduler.cancel(id)

        clock.advance(1_000)
        await sleeper.advance(by: 1_000)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await counter.read() == 0)
        #expect(await scheduler.state(of: id) == .cancelled)
    }

    @Test("Multiple events, all reach .fired after deadlines pass")
    func multipleFire() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        let id1 = await scheduler.schedule(atSyncedTime: 100) {
            Task { await counter.increment() }
        }
        let id2 = await scheduler.schedule(atSyncedTime: 200) {
            Task { await counter.increment() }
        }
        let id3 = await scheduler.schedule(atSyncedTime: 300) {
            Task { await counter.increment() }
        }

        try await Task.sleep(nanoseconds: 80_000_000)
        clock.advance(300)
        await sleeper.advance(by: 300)
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(await counter.read() == 3)
        #expect(await scheduler.state(of: id1) == .fired)
        #expect(await scheduler.state(of: id2) == .fired)
        #expect(await scheduler.state(of: id3) == .fired)
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

        let id = await scheduler.schedule(atSyncedTime: 100_000_000) { // 100ms target
            Task { await counter.increment() }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        // Sleeper releases at 100ms, but advance the clock by 200ms first
        // — simulating a late OS wakeup.
        clock.advance(200_000_000)
        await sleeper.advance(by: 100_000_000)
        try await Task.sleep(nanoseconds: 100_000_000)

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

        try await Task.sleep(nanoseconds: 50_000_000)
        await scheduler.handleJump(oldOffsetNs: 1_000_000, newOffsetNs: 20_000_000)

        try await Task.sleep(nanoseconds: 100_000_000)
        collector.cancel()
        let event = await collector.value
        guard case .driftWarning(let evID, let oldNs, let newNs) = event else {
            Issue.record("Expected driftWarning, got \(String(describing: event))")
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

        try await Task.sleep(nanoseconds: 50_000_000)
        await scheduler.shutdown()

        clock.advance(2_000)
        await sleeper.advance(by: 2_000)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await counter.read() == 0)
        #expect(await scheduler.state(of: id1) == .cancelled)
        #expect(await scheduler.state(of: id2) == .cancelled)
    }

    // MARK: - handleJump rescheduling tests

    @Test("handleJump: 未来 event を新時間軸で再スケジュール")
    func handleJumpReschedulesToNewTimeline() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        // now=0, target=1_000_000_000 でスケジュール（1s 先）
        let id = await scheduler.schedule(atSyncedTime: 1_000_000_000) {
            Task { await counter.increment() }
        }
        // Sleeper が sleep enqueue されるのを待つ
        try await Task.sleep(nanoseconds: 50_000_000)

        // now を 500_000_000 に進める（clock のみ進め、sleeper は進めない）
        clock.advance(500_000_000)

        // jump 発生 → 古い Task cancel → 新 delay = 1_000_000_000 - 500_000_000 = 500_000_000 で再スケジュール
        await scheduler.handleJump(oldOffsetNs: 0, newOffsetNs: 5_000_000)

        // 新しい sleeper waiter が enqueue されるのを待つ
        try await Task.sleep(nanoseconds: 50_000_000)

        // 新 delay 分 sleeper を進める
        clock.advance(500_000_000)
        await sleeper.advance(by: 500_000_000)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await counter.read() == 1)
        #expect(await scheduler.state(of: id) == .fired)
    }

    @Test("handleJump: 過去化した event は即時 fire (missed)")
    func handleJumpFiresPastEventImmediately() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        // target=1_000_000_000 でスケジュール
        let id = await scheduler.schedule(atSyncedTime: 1_000_000_000) {
            Task { await counter.increment() }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // now を target を超えた時刻まで進める（jump で過去化）
        clock.advance(2_000_000_000)

        // handleJump → delay <= 0 → tryFire(forceMissed: true) が即座に呼ばれる
        await scheduler.handleJump(oldOffsetNs: 0, newOffsetNs: 1_000_000_000)

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(await counter.read() == 1)
        #expect(await scheduler.state(of: id) == .missed)
    }

    @Test("handleJump: 複数 pending を全件再照準")
    func handleJumpReschedulesAllPending() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        // now=0 で 3 件スケジュール
        let id1 = await scheduler.schedule(atSyncedTime: 1_000_000_000) {
            Task { await counter.increment() }
        }
        let id2 = await scheduler.schedule(atSyncedTime: 2_000_000_000) {
            Task { await counter.increment() }
        }
        let id3 = await scheduler.schedule(atSyncedTime: 3_000_000_000) {
            Task { await counter.increment() }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        // now を 500_000_000 に進める
        clock.advance(500_000_000)

        // handleJump: 古い 3 Task cancel → 各々 delay = target - 500_000_000 で再スケジュール
        await scheduler.handleJump(oldOffsetNs: 0, newOffsetNs: 5_000_000)

        try await Task.sleep(nanoseconds: 50_000_000)

        // 3 件すべての新 deadline を超える分だけ進める（最大 = 3_000_000_000 - 500_000_000 = 2_500_000_000）
        clock.advance(2_500_000_000)
        await sleeper.advance(by: 2_500_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(await counter.read() == 3)
        #expect(await scheduler.state(of: id1) == .fired)
        #expect(await scheduler.state(of: id2) == .fired)
        #expect(await scheduler.state(of: id3) == .fired)
    }

    @Test("handleJump: 二重実行されない")
    func handleJumpNoDoubleFire() async throws {
        let clock = VClock()
        let sleeper = MockSleeper()
        let scheduler = EventScheduler(now: { clock.read() }, sleeper: sleeper)
        let counter = Counter()

        // target=1_000_000_000 で 1 件スケジュール
        let id = await scheduler.schedule(atSyncedTime: 1_000_000_000) {
            Task { await counter.increment() }
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        clock.advance(100_000_000)

        // handleJump を 2 回連続で呼ぶ（各回で delay > 0 → 再スケジュール）
        await scheduler.handleJump(oldOffsetNs: 0, newOffsetNs: 5_000_000)
        try await Task.sleep(nanoseconds: 30_000_000)
        await scheduler.handleJump(oldOffsetNs: 5_000_000, newOffsetNs: 10_000_000)

        try await Task.sleep(nanoseconds: 50_000_000)

        // 最終 delay 分を超えて進める
        clock.advance(2_000_000_000)
        await sleeper.advance(by: 2_000_000_000)
        try await Task.sleep(nanoseconds: 150_000_000)

        // tryFire の state guard により 1 回しか実行されない
        #expect(await counter.read() == 1)
        #expect(await scheduler.state(of: id) == .fired)
    }
}
