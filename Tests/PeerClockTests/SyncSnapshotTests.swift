import Testing
import Foundation
@testable import PeerClock

@Suite("SyncSnapshot")
struct SyncSnapshotTests {

    private func makeQuality() -> SyncQuality {
        SyncQuality(offsetNs: 0, roundTripDelayNs: 1000, confidence: 1.0)
    }

    @Test("synced + 鮮度内 → isSynchronized true")
    func freshSyncedIsTrue() {
        let snap = SyncSnapshot(
            state: .synced(offset: 0.001, quality: makeQuality()),
            offset: 0.001,
            quality: makeQuality(),
            lastSyncedAt: 1_000_000_000,
            capturedAt: 1_500_000_000,
            staleAfterNs: 1_000_000_000
        )
        #expect(snap.isSynchronized == true)
    }

    @Test("境界: 経過時間 == staleAfter ちょうど → true")
    func boundaryEqualStaleAfter() {
        let snap = SyncSnapshot(
            state: .synced(offset: 0, quality: makeQuality()),
            offset: 0,
            quality: makeQuality(),
            lastSyncedAt: 1_000_000_000,
            capturedAt: 2_000_000_000,
            staleAfterNs: 1_000_000_000
        )
        #expect(snap.isSynchronized == true)
    }

    @Test("経過時間 > staleAfter → false")
    func staleAfterExceeded() {
        let snap = SyncSnapshot(
            state: .synced(offset: 0, quality: makeQuality()),
            offset: 0,
            quality: makeQuality(),
            lastSyncedAt: 1_000_000_000,
            capturedAt: 2_000_000_001,
            staleAfterNs: 1_000_000_000
        )
        #expect(snap.isSynchronized == false)
    }

    @Test("state .syncing → false")
    func notSyncedState() {
        let snap = SyncSnapshot(
            state: .syncing,
            offset: 0,
            quality: nil,
            lastSyncedAt: nil,
            capturedAt: 1_000_000_000,
            staleAfterNs: 1_000_000_000
        )
        #expect(snap.isSynchronized == false)
    }

    @Test("state .idle → false")
    func idleState() {
        let snap = SyncSnapshot(
            state: .idle,
            offset: 0,
            quality: nil,
            lastSyncedAt: nil,
            capturedAt: 1_000_000_000,
            staleAfterNs: 1_000_000_000
        )
        #expect(snap.isSynchronized == false)
    }

    @Test("単調時計後退 (capturedAt < lastSyncedAt) → false")
    func monotonicRegression() {
        let snap = SyncSnapshot(
            state: .synced(offset: 0, quality: makeQuality()),
            offset: 0,
            quality: makeQuality(),
            lastSyncedAt: 2_000_000_000,
            capturedAt: 1_000_000_000,
            staleAfterNs: 5_000_000_000
        )
        #expect(snap.isSynchronized == false)
    }

    @Test("lastSyncedAt nil → false")
    func nilLastSyncedAt() {
        let snap = SyncSnapshot(
            state: .synced(offset: 0, quality: makeQuality()),
            offset: 0,
            quality: makeQuality(),
            lastSyncedAt: nil,
            capturedAt: 1_000_000_000,
            staleAfterNs: 1_000_000_000
        )
        #expect(snap.isSynchronized == false)
    }
}
