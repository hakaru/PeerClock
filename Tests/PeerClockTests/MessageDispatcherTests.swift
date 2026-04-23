import Testing
import Foundation
@testable import PeerClock

@Suite("MessageDispatcher")
struct MessageDispatcherTests {
    @Test func ntpBeatsEverything() async {
        let d = MessageDispatcher()
        await d.enqueue(.init(data: Data([1]), priority: .control))
        await d.enqueue(.init(data: Data([2]), priority: .ntp))
        let first = await d.dequeue()
        #expect(first?.data == Data([2]))
    }

    @Test func criticalBeatsControl() async {
        let d = MessageDispatcher()
        await d.enqueue(.init(data: Data([1]), priority: .control))
        await d.enqueue(.init(data: Data([2]), priority: .critical))
        let first = await d.dequeue()
        #expect(first?.data == Data([2]))
    }

    @Test func statusLatestOnly() async {
        let d = MessageDispatcher()
        await d.enqueue(.init(data: Data([1]), priority: .status))
        await d.enqueue(.init(data: Data([2]), priority: .status))
        let first = await d.dequeue()
        #expect(first?.data == Data([2]))  // second replaced first
        let second = await d.dequeue()
        #expect(second == nil)
    }

    @Test func heartbeatLatestOnly() async {
        let d = MessageDispatcher()
        await d.enqueue(.init(data: Data([1]), priority: .heartbeat))
        await d.enqueue(.init(data: Data([2]), priority: .heartbeat))
        let first = await d.dequeue()
        #expect(first?.data == Data([2]))
    }

    @Test func ntpBypassesBackpressure() async {
        let d = MessageDispatcher()
        // Fill non-critical buffer
        for i in 0..<10 {
            await d.enqueue(.init(data: Data([UInt8(i)]), priority: .control))
        }
        // NTP can still be enqueued and comes first
        await d.enqueue(.init(data: Data([99]), priority: .ntp))
        let first = await d.dequeue()
        #expect(first?.data == Data([99]))
    }

    @Test func criticalNeverDropped() async {
        let d = MessageDispatcher()
        // Fill control buffer
        for i in 0..<10 {
            await d.enqueue(.init(data: Data([UInt8(i)]), priority: .control))
        }
        // Critical added — should be retained and dequeued before any control
        await d.enqueue(.init(data: Data([99]), priority: .critical))
        let first = await d.dequeue()
        #expect(first?.data == Data([99]))
    }

    @Test func controlDropsOldestOverLimit() async {
        let d = MessageDispatcher()
        for i in 0..<10 {
            await d.enqueue(.init(data: Data([UInt8(i)]), priority: .control))
        }
        // Should have only the latest 8 (max), dropping oldest
        // First dequeued should be the 3rd one (index 2)
        let first = await d.dequeue()
        #expect(first?.data == Data([2]))
    }

    @Test func slowClientDetection() async {
        let d = MessageDispatcher()
        // No backpressure initially
        #expect(await d.isSlowClient(threshold: 0.1) == false)

        // Fill to trigger backpressure
        for i in 0..<10 {
            await d.enqueue(.init(data: Data([UInt8(i)]), priority: .control))
        }

        // Wait past threshold
        try? await Task.sleep(for: .milliseconds(150))
        #expect(await d.isSlowClient(threshold: 0.1) == true)

        // Drain and verify backpressure clears
        for _ in 0..<8 { _ = await d.dequeue() }
        // Re-enqueue a small amount to trigger updateBackpressureState
        await d.enqueue(.init(data: Data([0]), priority: .control))
        #expect(await d.isSlowClient(threshold: 0.1) == false)
    }
}
