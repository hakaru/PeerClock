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
}
