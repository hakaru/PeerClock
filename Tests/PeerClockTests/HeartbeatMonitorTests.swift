// Tests/PeerClockTests/HeartbeatMonitorTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("HeartbeatMonitor")
struct HeartbeatMonitorTests {

    /// Synchronous virtual clock for tests. Uses NSLock for thread safety so it
    /// can be read from a `@Sendable () -> TimeInterval` closure.
    final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 0
        func advance(_ dt: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            t += dt
        }
        func read() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return t
        }
    }

    private func makeMonitor(clock: VirtualClock) -> HeartbeatMonitor {
        HeartbeatMonitor(
            interval: 1.0,
            degradedAfter: 2.0,
            disconnectedAfter: 5.0,
            now: { clock.read() },
            broadcast: { }
        )
    }

    @Test("connected → degraded → disconnected on elapsed time")
    func stateTransitions() async {
        let clock = VirtualClock()
        let monitor = makeMonitor(clock: clock)

        let peer = PeerID(rawValue: UUID())
        await monitor.heartbeatReceived(from: peer)
        #expect(await monitor.currentState(of: peer) == .connected)

        clock.advance(1.0)
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .connected)

        clock.advance(1.5) // total 2.5s
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .degraded)

        clock.advance(3.0) // total 5.5s
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .disconnected)
    }

    @Test("Receiving a heartbeat restores to connected")
    func recovery() async {
        let clock = VirtualClock()
        let monitor = makeMonitor(clock: clock)
        let peer = PeerID(rawValue: UUID())
        await monitor.heartbeatReceived(from: peer)

        clock.advance(2.5)
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .degraded)

        await monitor.heartbeatReceived(from: peer)
        #expect(await monitor.currentState(of: peer) == .connected)
    }

    @Test("peerLeft clears tracking")
    func peerLeftClears() async {
        let clock = VirtualClock()
        let monitor = makeMonitor(clock: clock)
        let peer = PeerID(rawValue: UUID())
        await monitor.heartbeatReceived(from: peer)
        await monitor.peerLeft(peer)
        #expect(await monitor.currentState(of: peer) == nil)
    }

    @Test("Event stream emits transitions in order")
    func eventStream() async {
        let clock = VirtualClock()
        let monitor = makeMonitor(clock: clock)
        let peer = PeerID(rawValue: UUID())

        let collector = Task { () -> [HeartbeatMonitor.Event] in
            var events: [HeartbeatMonitor.Event] = []
            for await e in monitor.events {
                events.append(e)
                if events.count == 3 { break }
            }
            return events
        }

        await monitor.heartbeatReceived(from: peer) // connected
        clock.advance(2.5); await monitor.evaluate() // degraded
        clock.advance(3.0); await monitor.evaluate() // disconnected

        let events = await collector.value
        #expect(events.count == 3)
        #expect(events.map { $0.state } == [.connected, .degraded, .disconnected])
    }
}
