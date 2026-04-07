// Tests/PeerClockTests/EventSchedulerIntegrationTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — EventScheduler integration")
struct EventSchedulerIntegrationTests {

    actor Box {
        var fired = false
        var firedAt: UInt64 = 0
        func mark(_ at: UInt64) { fired = true; firedAt = at }
        func read() -> Bool { fired }
        func readAt() -> UInt64 { firedAt }
    }

    @Test("schedule via facade fires after real wait")
    func facadeFires() async throws {
        let network = MockNetwork()
        let clock = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await clock.start()

        let box = Box()
        let when = clock.now + 80_000_000 // 80ms 後
        let handle = await clock.schedule(atSyncedTime: when) {
            let t = NTPSyncEngine.now()
            Task { await box.mark(t) }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await box.read() == true)
        let s = await handle.state()
        #expect(s == .fired || s == .missed)

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
        let when = clock.now + 200_000_000 // 200ms 後
        let handle = await clock.schedule(atSyncedTime: when) {
            let t = NTPSyncEngine.now()
            Task { await box.mark(t) }
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

        // 同期が収束するまで待つ
        try await Task.sleep(nanoseconds: 1_500_000_000)

        actor Times {
            var marks: [(String, UInt64)] = []
            func add(_ tag: String, _ t: UInt64) { marks.append((tag, t)) }
            func read() -> [(String, UInt64)] { marks }
        }
        let times = Times()

        // A の now + 200ms を共有ターゲットとして両方に予約
        let target = a.now + 200_000_000
        _ = await a.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await times.add("a", t) }
        }
        _ = await b.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await times.add("b", t) }
        }

        try await Task.sleep(nanoseconds: 600_000_000)

        let marks = await times.read()
        #expect(marks.count == 2)
        if marks.count == 2 {
            let dt = Int64(marks[0].1) - Int64(marks[1].1)
            // CI でのジッター考慮: 50ms 以内を許容
            #expect(abs(dt) < 50_000_000)
        }

        await a.stop()
        await b.stop()
    }
}
