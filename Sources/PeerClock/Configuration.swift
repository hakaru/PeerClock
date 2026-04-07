import Foundation

/// Runtime configuration for a PeerClock instance.
public struct Configuration: Sendable {

    // MARK: - Heartbeat

    /// Interval in seconds between heartbeat packets.
    public let heartbeatInterval: TimeInterval

    /// After this many seconds with no heartbeat, a peer is marked `.degraded`.
    public let degradedAfter: TimeInterval

    /// After this many seconds with no heartbeat, a peer is marked `.disconnected`.
    public let disconnectedAfter: TimeInterval

    // MARK: - Reconnect

    /// Transport 層の再接続リトライ間隔。
    public let reconnectRetryInterval: TimeInterval

    /// Transport 層の再接続リトライ最大回数。
    public let reconnectMaxAttempts: Int

    // MARK: - Status debounce

    /// Send-side debounce window. `setStatus` calls within this window are
    /// flushed into a single STATUS_PUSH.
    public let statusSendDebounce: TimeInterval

    /// Receive-side debounce window. `statusUpdates` events for the same peer
    /// within this window are collapsed to one.
    public let statusReceiveDebounce: TimeInterval

    // MARK: - Clock sync

    /// Interval in seconds between sync rounds.
    ///
    /// - Note: Deprecated. Use ``syncBackoffStages`` instead.
    ///   `NTPSyncEngine` no longer reads this field; it is retained for source compatibility only.
    public let syncInterval: TimeInterval

    /// Backoff stages (秒)。同期成功が連続するとこの順で sync interval が延長される。
    /// 既存の `syncInterval` は deprecated 扱い (NTPSyncEngine 内部では未使用)。
    public let syncBackoffStages: [TimeInterval]

    /// 各段階で次の段階へ昇格するために必要な連続成功回数。
    public let syncBackoffPromoteAfter: Int

    /// schedule() がガードする最小同期信頼度 (0.0..1.0)。
    /// `quality.confidence < minSyncQuality` の場合 `qualityBelowThreshold` を throw。
    /// 比較は厳密未満なので `==` は通過する。
    public let minSyncQuality: Double

    /// SyncSnapshot.isSynchronized が true となる最終同期からの最大経過時間。
    /// デフォルト 90 秒 (Phase 3.5 のバックオフ最大 30s × 2 + マージン)。
    public let syncStaleAfter: Duration

    /// 内部用: syncStaleAfter のナノ秒換算
    internal var syncStaleAfterNs: UInt64 {
        let comps = syncStaleAfter.components
        let secNs = UInt64(max(0, comps.seconds)) * 1_000_000_000
        let attoNs = UInt64(max(0, comps.attoseconds / 1_000_000_000))
        return secNs &+ attoNs
    }

    /// Number of timing measurements per sync round.
    public let syncMeasurements: Int

    /// Interval in seconds between individual measurements within a sync round.
    public let syncMeasurementInterval: TimeInterval

    // MARK: - MultipeerConnectivity

    public var mcServiceType: String

    public var mcMaxPeers: Int

    // MARK: - Transport

    /// Bonjour service type string.
    public let serviceType: String

    /// Wire protocol version used in HELLO negotiation.
    public let protocolVersion: UInt16

    public init(
        heartbeatInterval: TimeInterval = 1.0,
        degradedAfter: TimeInterval = 2.0,
        disconnectedAfter: TimeInterval = 5.0,
        reconnectRetryInterval: TimeInterval = 0.5,
        reconnectMaxAttempts: Int = 3,
        statusSendDebounce: TimeInterval = 0.1,
        statusReceiveDebounce: TimeInterval = 0.05,
        syncInterval: TimeInterval = 5.0,
        syncBackoffStages: [TimeInterval] = [5.0, 10.0, 20.0, 30.0],
        syncBackoffPromoteAfter: Int = 3,
        minSyncQuality: Double = 0.5,
        syncStaleAfter: Duration = .seconds(90),
        syncMeasurements: Int = 40,
        syncMeasurementInterval: TimeInterval = 0.03,
        mcServiceType: String = "peerclock-mpc",
        mcMaxPeers: Int = 8,
        serviceType: String = "_peerclock._udp",
        protocolVersion: UInt16 = 1
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.degradedAfter = degradedAfter
        self.disconnectedAfter = disconnectedAfter
        self.reconnectRetryInterval = reconnectRetryInterval
        self.reconnectMaxAttempts = reconnectMaxAttempts
        self.statusSendDebounce = statusSendDebounce
        self.statusReceiveDebounce = statusReceiveDebounce
        self.syncInterval = syncInterval
        self.syncBackoffStages = syncBackoffStages
        self.syncBackoffPromoteAfter = syncBackoffPromoteAfter
        self.minSyncQuality = minSyncQuality
        self.syncStaleAfter = syncStaleAfter
        self.syncMeasurements = syncMeasurements
        self.syncMeasurementInterval = syncMeasurementInterval
        self.mcServiceType = mcServiceType
        self.mcMaxPeers = mcMaxPeers
        self.serviceType = serviceType
        self.protocolVersion = protocolVersion
    }

    /// Default configuration with sensible values.
    public static let `default` = Configuration()
}
