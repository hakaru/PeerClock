import Foundation

/// Runtime configuration for a PeerClock instance.
public struct Configuration: Sendable {

    /// Interval in seconds between heartbeat packets.
    public let heartbeatInterval: TimeInterval

    /// Number of missed heartbeats before a peer is considered disconnected.
    public let disconnectThreshold: Int

    /// Interval in seconds between sync rounds.
    public let syncInterval: TimeInterval

    /// Number of timing measurements per sync round.
    public let syncMeasurements: Int

    /// Interval in seconds between individual measurements within a sync round.
    public let syncMeasurementInterval: TimeInterval

    /// Bonjour service type string.
    public let serviceType: String

    /// Wire protocol version used in HELLO negotiation.
    public let protocolVersion: UInt16

    public init(
        heartbeatInterval: TimeInterval = 1.0,
        disconnectThreshold: Int = 3,
        syncInterval: TimeInterval = 5.0,
        syncMeasurements: Int = 40,
        syncMeasurementInterval: TimeInterval = 0.03,
        serviceType: String = "_peerclock._udp",
        protocolVersion: UInt16 = 1
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.disconnectThreshold = disconnectThreshold
        self.syncInterval = syncInterval
        self.syncMeasurements = syncMeasurements
        self.syncMeasurementInterval = syncMeasurementInterval
        self.serviceType = serviceType
        self.protocolVersion = protocolVersion
    }

    /// Default configuration with sensible values.
    public static let `default` = Configuration()
}
