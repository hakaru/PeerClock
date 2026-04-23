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
}
