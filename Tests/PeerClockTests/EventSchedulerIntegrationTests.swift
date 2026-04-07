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

    /// Poll for isSynchronized with a deadline (retries every 50ms up to maxMs).
    private static func waitForSync(_ clock: PeerClock, maxMs: Int = 3000) async {
        let deadline = Date().addingTimeInterval(Double(maxMs) / 1000.0)
        while Date() < deadline {
            if clock.currentSync.isSynchronized { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private static func fastSyncConfig() -> Configuration {
        Configuration(
            heartbeatInterval: 0.1,
            degradedAfter: 0.5,
            disconnectedAfter: 1.0,
            syncBackoffStages: [0.1],
            syncBackoffPromoteAfter: 1,
            syncMeasurements: 2,
            syncMeasurementInterval: 0.005
        )
    }

    @Test("schedule via facade fires after real wait")
    func facadeFires() async throws {
        let network = MockNetwork()
        let config = Self.fastSyncConfig()
        let clockA = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let clockB = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await clockA.start()
        try await clockB.start()
        // 同期完了を待つ
        await Self.waitForSync(clockA); await Self.waitForSync(clockB)

        let box = Box()
        let when = clockA.now + 80_000_000 // 80ms 後
        let handle = try await clockA.schedule(atSyncedTime: when) {
            let t = NTPSyncEngine.now()
            Task { await box.mark(t) }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(await box.read() == true)
        let s = await handle.state()
        #expect(s == .fired || s == .missed)

        await clockA.stop()
        await clockB.stop()
    }

    @Test("schedule cancel via handle prevents fire")
    func cancelViaHandle() async throws {
        let network = MockNetwork()
        let config = Self.fastSyncConfig()
        let clockA = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let clockB = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await clockA.start()
        try await clockB.start()
        await Self.waitForSync(clockA); await Self.waitForSync(clockB)

        let box = Box()
        let when = clockA.now + 200_000_000 // 200ms 後
        let handle = try await clockA.schedule(atSyncedTime: when) {
            let t = NTPSyncEngine.now()
            Task { await box.mark(t) }
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await handle.cancel()

        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(await box.read() == false)
        #expect(await handle.state() == .cancelled)

        await clockA.stop()
        await clockB.stop()
    }

    @Test("Two peers fire near-simultaneously at the same synced time")
    func twoPeersFireTogether() async throws {
        let network = MockNetwork()
        let config = Self.fastSyncConfig()
        let a = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await a.start()
        try await b.start()

        // 同期が収束するまで待つ
        await Self.waitForSync(a); await Self.waitForSync(b)

        actor Times {
            var marks: [(String, UInt64)] = []
            func add(_ tag: String, _ t: UInt64) { marks.append((tag, t)) }
            func read() -> [(String, UInt64)] { marks }
        }
        let times = Times()

        // A の now + 200ms を共有ターゲットとして両方に予約
        let target = a.now + 200_000_000
        _ = try await a.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await times.add("a", t) }
        }
        _ = try await b.schedule(atSyncedTime: target) {
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
