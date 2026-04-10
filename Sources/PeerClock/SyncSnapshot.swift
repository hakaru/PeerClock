import Foundation

/// Atomic snapshot of `PeerClock`'s synchronization state.
///
/// Obtain via `PeerClock.currentSync`. Use `isSynchronized` to check both sync
/// state and freshness before scheduling events.
public struct SyncSnapshot: Sendable {
    /// The most recent sync lifecycle state.
    public let state: SyncState
    /// Current clock offset in seconds (`0` when not synchronized).
    public let offset: TimeInterval
    /// Quality metrics from the last sync round, or `nil`.
    public let quality: SyncQuality?
    /// Monotonic timestamp in nanoseconds of the last `.synced` transition, or
    /// `nil`.
    public let lastSyncedAt: UInt64?
    /// Monotonic timestamp in nanoseconds when this snapshot was captured.
    public let capturedAt: UInt64
    /// 鮮度判定用の閾値 (Configuration.syncStaleAfter のナノ秒換算)
    private let staleAfterNs: UInt64

    public init(
        state: SyncState,
        offset: TimeInterval,
        quality: SyncQuality?,
        lastSyncedAt: UInt64?,
        capturedAt: UInt64,
        staleAfterNs: UInt64
    ) {
        self.state = state
        self.offset = offset
        self.quality = quality
        self.lastSyncedAt = lastSyncedAt
        self.capturedAt = capturedAt
        self.staleAfterNs = staleAfterNs
    }

    /// `true` when synced and the last sync is within
    /// `Configuration.syncStaleAfter`.
    public var isSynchronized: Bool {
        guard case .synced = state, let last = lastSyncedAt else { return false }
        guard capturedAt >= last else { return false }
        return capturedAt - last <= staleAfterNs
    }
}
