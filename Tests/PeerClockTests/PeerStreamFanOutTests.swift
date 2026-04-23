import Testing
import Foundation
@testable import PeerClock

@Suite("PeerStreamFanOut")
struct PeerStreamFanOutTests {

    @Test("two subscribers receive identical publish sequence")
    func twoSubscribersAgree() async throws {
        let fanOut = PeerStreamFanOut<[Int]>()
        // subscribe before publish so nothing is replayed
        let a = fanOut.subscribe(replayLast: false)
        let b = fanOut.subscribe(replayLast: false)

        fanOut.publish([1])
        fanOut.publish([])

        var ait = a.makeAsyncIterator()
        var bit = b.makeAsyncIterator()
        let a0 = await ait.next()
        let b0 = await bit.next()
        let a1 = await ait.next()
        let b1 = await bit.next()

        #expect(a0 == [1])
        #expect(b0 == [1])
        #expect(a1 == [])
        #expect(b1 == [])
    }

    @Test("late subscriber receives the last published value by default")
    func replayLast() async throws {
        let fanOut = PeerStreamFanOut<Int>()
        fanOut.publish(42)
        let s = fanOut.subscribe() // replayLast defaults to true
        var it = s.makeAsyncIterator()
        let v = await it.next()
        #expect(v == 42)
    }

    @Test("subscribing with replayLast=false does not replay")
    func noReplay() async throws {
        let fanOut = PeerStreamFanOut<Int>()
        fanOut.publish(42)
        let s = fanOut.subscribe(replayLast: false)
        var it = s.makeAsyncIterator()
        async let r = it.next()
        fanOut.publish(99)
        let v = await r
        #expect(v == 99)
    }

    @Test("finish completes all active subscribers")
    func finishCompletes() async throws {
        let fanOut = PeerStreamFanOut<Int>()
        let s = fanOut.subscribe(replayLast: false)
        fanOut.finish()
        var it = s.makeAsyncIterator()
        let r = await it.next()
        #expect(r == nil)
    }

    @Test("lastValue tracks the most recent publish")
    func lastValueTracks() {
        let fanOut = PeerStreamFanOut<Int>()
        #expect(fanOut.lastValue == nil)
        fanOut.publish(1)
        #expect(fanOut.lastValue == 1)
        fanOut.publish(2)
        #expect(fanOut.lastValue == 2)
    }

    /// Regression for the post-release review gap: a subscriber whose
    /// iteration Task gets cancelled must be removed from the continuations
    /// dict so we don't leak continuations across cancelled consumers.
    @Test("subscriber cancellation removes its continuation (onTermination)")
    func cancellationRemovesContinuation() async throws {
        let fanOut = PeerStreamFanOut<Int>()

        let task = Task {
            var count = 0
            for await _ in fanOut.subscribe(replayLast: false) {
                count += 1
            }
            return count
        }

        // Give the Task a moment to register its continuation
        try await Task.sleep(for: .milliseconds(50))
        #expect(fanOut.subscriberCount == 1)

        task.cancel()
        // onTermination fires synchronously inside AsyncStream cleanup; still
        // give it a scheduling window.
        try await Task.sleep(for: .milliseconds(50))

        #expect(fanOut.subscriberCount == 0)
    }

    /// finish() must drop all live subscribers from the dict (not just yield
    /// finish on their continuations).
    @Test("finish() empties the subscriber dict")
    func finishEmptiesDict() async throws {
        let fanOut = PeerStreamFanOut<Int>()

        // Subscribers register their continuation lazily — via iteration.
        // Start three Tasks that actually iterate so the dict populates.
        let tasks = (0..<3).map { _ in
            Task {
                for await _ in fanOut.subscribe(replayLast: false) {}
            }
        }

        // Give the tasks a scheduling window to register
        try await Task.sleep(for: .milliseconds(50))
        #expect(fanOut.subscriberCount == 3)

        fanOut.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fanOut.subscriberCount == 0)

        for task in tasks { await task.value }
    }

    /// Subscribing after finish() must not leave a dangling continuation.
    @Test("subscribe-after-finish does not register a continuation")
    func subscribeAfterFinishNoLeak() async throws {
        let fanOut = PeerStreamFanOut<Int>()
        fanOut.finish()
        let s = fanOut.subscribe(replayLast: false)

        // The continuation is finished at subscribe time, so no state is held.
        #expect(fanOut.subscriberCount == 0)

        // The returned stream terminates immediately.
        var it = s.makeAsyncIterator()
        let v = await it.next()
        #expect(v == nil)
    }
}
