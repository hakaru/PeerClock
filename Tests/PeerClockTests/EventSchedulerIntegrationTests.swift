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

    /// Wait up to maxMs for clock to be synchronized (polling).
    private static func waitForSync(_ clock: PeerClock, maxMs: Int = 2000) async {
        let deadline = Date().addingTimeInterval(Double(maxMs) / 1000.0)
        while Date() < deadline {
            if clock.currentSync.isSynchronized { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// Return whichever of the two peers is the current coordinator in a
    /// 2-peer cluster. Tests that only need one synchronized peer can use this
    /// helper instead of branching on leadership directly.
    private static func coordinatorPeer(_ a: PeerClock, _ b: PeerClock) -> PeerClock {
        a.coordinatorID == a.localPeerID ? a : b
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
        await Self.waitForSync(clockA)
        await Self.waitForSync(clockB)

        let coord = Self.coordinatorPeer(clockA, clockB)
        let box = Box()
        let when = coord.now + 80_000_000
        let handle = try await coord.schedule(atSyncedTime: when) {
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
        await Self.waitForSync(clockA)
        await Self.waitForSync(clockB)

        let coord = Self.coordinatorPeer(clockA, clockB)
        let box = Box()
        let when = coord.now + 200_000_000
        let handle = try await coord.schedule(atSyncedTime: when) {
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

    @Test("two peers fire together")
    func twoPeersFireTogether() async throws {
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
        await Self.waitForSync(clockA)
        await Self.waitForSync(clockB)

        #expect(clockA.currentSync.isSynchronized == true)
        #expect(clockB.currentSync.isSynchronized == true)

        let boxA = Box()
        let boxB = Box()
        let target = max(clockA.now, clockB.now) + 150_000_000

        _ = try await clockA.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await boxA.mark(t) }
        }
        _ = try await clockB.schedule(atSyncedTime: target) {
            let t = NTPSyncEngine.now()
            Task { await boxB.mark(t) }
        }

        try await Task.sleep(nanoseconds: 450_000_000)

        #expect(await boxA.read() == true)
        #expect(await boxB.read() == true)

        let firedAtA = await boxA.readAt()
        let firedAtB = await boxB.readAt()
        let delta = firedAtA >= firedAtB ? firedAtA - firedAtB : firedAtB - firedAtA
        #expect(delta <= 50_000_000)

        await clockA.stop()
        await clockB.stop()
    }
}
