import Foundation

/// PeerClock の同期状態のアトミックスナップショット。
///
/// `PeerClock.currentSync` から取得する。`isSynchronized` は同期状態だけでなく
/// 鮮度 (最終同期からの経過時間) も判定する。
public struct SyncSnapshot: Sendable {
    /// 直近の同期状態
    public let state: SyncState
    /// 現在のオフセット (秒、未同期時は 0)
    public let offset: TimeInterval
    /// 直近の品質情報 (未同期時は nil)
    public let quality: SyncQuality?
    /// 直近に .synced へ遷移した時刻 (CLOCK_MONOTONIC ns、未同期時は nil)
    public let lastSyncedAt: UInt64?
    /// このスナップショットを取得した時刻 (CLOCK_MONOTONIC ns)
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

    /// 同期済み かつ Configuration.syncStaleAfter 以内に最終同期している。
    /// `capturedAt < lastSyncedAt` の異常時計後退ケースは false 扱い (防御コード)。
    public var isSynchronized: Bool {
        guard case .synced = state, let last = lastSyncedAt else { return false }
        guard capturedAt >= last else { return false }
        return capturedAt - last <= staleAfterNs
    }
}
