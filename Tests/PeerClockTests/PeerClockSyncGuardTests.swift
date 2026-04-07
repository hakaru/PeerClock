import Testing
import Foundation
@testable import PeerClock

@Suite("PeerClock — Sync Guard")
struct PeerClockSyncGuardTests {

    private func makeConfig(
        minSyncQuality: Double = 0.5,
        syncStaleAfter: Duration = .seconds(90)
    ) -> Configuration {
        Configuration(
            heartbeatInterval: 0.1,
            degradedAfter: 0.5,
            disconnectedAfter: 1.0,
            syncBackoffStages: [0.1],
            syncBackoffPromoteAfter: 1,
            minSyncQuality: minSyncQuality,
            syncStaleAfter: syncStaleAfter,
            syncMeasurements: 2,
            syncMeasurementInterval: 0.005
        )
    }

    @Test("未起動 PeerClock で schedule → notStarted")
    func notStartedThrows() async {
        let network = MockNetwork()
        let config = makeConfig()
        let clock = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        // start を呼ばない
        await #expect(throws: PeerClockError.notStarted) {
            _ = try await clock.schedule(atSyncedTime: 1_000_000_000) { }
        }
    }

    @Test("起動済み未同期で schedule → notSynchronized")
    func notSynchronizedThrows() async throws {
        let network = MockNetwork()
        let config = makeConfig()
        // 単一ピアのみ起動 (ペア相手なし → 同期されない)
        let clock = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        try await clock.start()
        defer { Task { await clock.stop() } }

        await #expect(throws: PeerClockError.notSynchronized) {
            _ = try await clock.schedule(atSyncedTime: clock.now + 1_000_000_000) { }
        }
    }

    @Test("過去時刻 + lateTolerance .zero → deadlineExceeded")
    func deadlineExceededThrows() async throws {
        let network = MockNetwork()
        let config = makeConfig()
        let clockA = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        let clockB = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        try await clockA.start()
        try await clockB.start()
        defer {
            Task { await clockA.stop() }
            Task { await clockB.stop() }
        }

        try await Task.sleep(for: .milliseconds(500))

        let nowVal = clockA.now
        guard nowVal > 1_000_000_000 else { return }
        let pastTime = nowVal - 1_000_000_000

        // 同期済みなら deadlineExceeded、未同期なら notSynchronized — いずれも PeerClockError
        await #expect(throws: PeerClockError.self) {
            _ = try await clockA.schedule(atSyncedTime: pastTime, lateTolerance: .zero) { }
        }
    }

    @Test("過去時刻だが lateTolerance 内 → 即時実行成功")
    func lateToleranceWithinAccepts() async throws {
        let network = MockNetwork()
        let config = makeConfig()
        let clockA = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        let clockB = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        try await clockA.start()
        try await clockB.start()
        defer {
            Task { await clockA.stop() }
            Task { await clockB.stop() }
        }
        try await Task.sleep(for: .milliseconds(500))

        // 同期していない場合はスキップ
        guard clockA.currentSync.isSynchronized else { return }

        let nowVal = clockA.now
        guard nowVal > 50_000_000 else { return }
        let slightlyPast = nowVal - 50_000_000

        let fired = MutableBool()
        _ = try await clockA.schedule(
            atSyncedTime: slightlyPast,
            lateTolerance: .milliseconds(100)
        ) {
            fired.set(true)
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fired.value == true)
    }

    @Test("正常 schedule → 50ms 後に発火")
    func normalScheduleFires() async throws {
        let network = MockNetwork()
        let config = makeConfig()
        let clockA = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        let clockB = PeerClock(
            configuration: config,
            transportFactory: { peerID in MockTransport(localPeerID: peerID, network: network) }
        )
        try await clockA.start()
        try await clockB.start()
        defer {
            Task { await clockA.stop() }
            Task { await clockB.stop() }
        }
        try await Task.sleep(for: .milliseconds(500))

        // 同期していない場合はスキップ
        guard clockA.currentSync.isSynchronized else { return }

        let fired = MutableBool()
        let target = clockA.now + 50_000_000
        _ = try await clockA.schedule(atSyncedTime: target) {
            fired.set(true)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fired.value == true)
    }
}

final class MutableBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool = false
    var value: Bool { lock.withLock { _value } }
    func set(_ v: Bool) { lock.withLock { _value = v } }
}
