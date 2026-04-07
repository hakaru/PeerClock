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
        #expect(elapsed >= .milliseconds(40))
    }

    @Test("MockSleeper resumes after advance reaches deadline")
    func mockResumes() async throws {
        let sleeper = MockSleeper()

        let task = Task { () -> String in
            try await sleeper.sleep(nanoseconds: 100)
            return "fired"
        }

        // Give the task a moment to enqueue.
        try await Task.sleep(nanoseconds: 50_000_000)

        await sleeper.advance(by: 100)

        let result = try await task.value
        #expect(result == "fired")
    }

    @Test("MockSleeper does not resume before deadline")
    func mockNoEarlyResume() async throws {
        let sleeper = MockSleeper()

        actor Flag { var hit = false; func set() { hit = true }; func read() -> Bool { hit } }
        let flag = Flag()

        let task = Task {
            try? await sleeper.sleep(nanoseconds: 1_000)
            await flag.set()
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await sleeper.advance(by: 500) // not enough
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(await flag.read() == false)

        await sleeper.advance(by: 500) // now enough
        _ = await task.value
        #expect(await flag.read() == true)
    }

    @Test("MockSleeper resumes multiple waiters based on deadline")
    func mockOrder() async throws {
        let sleeper = MockSleeper()

        // Verify that advance(by:) only wakes waiters whose deadline has been reached,
        // and leaves the rest pending.
        let t1 = Task { () -> String in
            try? await sleeper.sleep(nanoseconds: 100)
            return "short"
        }
        let t2 = Task { () -> String in
            try? await sleeper.sleep(nanoseconds: 300)
            return "long"
        }

        try await Task.sleep(nanoseconds: 80_000_000)

        // Advance only enough to wake the short waiter (deadline=100), not the long one (deadline=300).
        await sleeper.advance(by: 100)

        // t1 must be done; t2 must still be pending.
        let shortResult = await t1.value
        #expect(shortResult == "short")
        #expect(await sleeper.pendingCount() == 1)

        // Now advance enough for the long waiter.
        await sleeper.advance(by: 200)
        let longResult = await t2.value
        #expect(longResult == "long")
        #expect(await sleeper.pendingCount() == 0)
    }

    @Test("MockSleeper cancelAll throws CancellationError to all waiters")
    func mockCancelAll() async throws {
        let sleeper = MockSleeper()

        let task = Task { () -> String in
            do {
                try await sleeper.sleep(nanoseconds: 1_000)
                return "fired"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "other"
            }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await sleeper.cancelAll()

        let result = await task.value
        #expect(result == "cancelled")
    }
}
