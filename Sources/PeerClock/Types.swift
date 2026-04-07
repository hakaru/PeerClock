import Foundation

// MARK: - Command

/// An application-level command sent between peers.
public struct Command: Sendable, Equatable {

    /// Command type identifier.
    public let type: String

    /// Optional binary payload.
    public let payload: Data

    public init(type: String, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

// MARK: - ConnectionState

/// The connection state between this device and a peer.
public enum ConnectionState: Sendable, Equatable {
    /// Peer is reachable and communicating normally.
    case connected
    /// Peer is reachable but experiencing packet loss or high latency.
    case degraded
    /// Peer is unreachable.
    case disconnected
}

// MARK: - SyncQuality

/// Metrics describing the quality of clock synchronization.
public struct SyncQuality: Sendable, Equatable {
    /// Clock offset relative to peer in nanoseconds.
    public let offsetNs: Int64
    /// Round-trip communication delay in nanoseconds.
    public let roundTripDelayNs: UInt64
    /// Confidence score in the range [0, 1].
    public let confidence: Double

    public init(offsetNs: Int64, roundTripDelayNs: UInt64, confidence: Double) {
        self.offsetNs = offsetNs
        self.roundTripDelayNs = roundTripDelayNs
        self.confidence = confidence
    }
}

// MARK: - SyncState

/// The synchronization lifecycle state of this PeerClock instance.
public enum SyncState: Sendable {
    /// Not started.
    case idle
    /// Scanning for peers on the network.
    case discovering
    /// Exchanging timing messages to compute offset.
    case syncing
    /// Clock is synchronized.
    case synced(offset: TimeInterval, quality: SyncQuality)
    /// Unrecoverable error.
    case error(String)
}

// MARK: - Platform

/// The Apple platform a device is running on.
public enum Platform: Sendable, Equatable {
    case iOS
    case macOS
}

// MARK: - DeviceInfo

/// Static metadata about a peer device.
public struct DeviceInfo: Sendable, Equatable {
    /// Human-readable device name.
    public let name: String
    /// Platform the device is running on.
    public let platform: Platform
    /// Battery level in [0, 1], or nil if unavailable.
    public let batteryLevel: Double?
    /// Available storage in bytes.
    public let storageAvailable: UInt64

    public init(name: String, platform: Platform, batteryLevel: Double? = nil, storageAvailable: UInt64) {
        self.name = name
        self.platform = platform
        self.batteryLevel = batteryLevel
        self.storageAvailable = storageAvailable
    }
}

// MARK: - PeerStatus

/// Live status of a connected peer.
public struct PeerStatus: Sendable {
    public let peerID: PeerID
    public let connectionState: ConnectionState
    public let syncQuality: SyncQuality?
    public let deviceInfo: DeviceInfo
    /// Application-defined key-value metadata.
    public let custom: [String: Data]
    /// Monotonically increasing counter; increments on each status update.
    public let generation: UInt64

    public init(
        peerID: PeerID,
        connectionState: ConnectionState,
        syncQuality: SyncQuality? = nil,
        deviceInfo: DeviceInfo,
        custom: [String: Data] = [:],
        generation: UInt64
    ) {
        self.peerID = peerID
        self.connectionState = connectionState
        self.syncQuality = syncQuality
        self.deviceInfo = deviceInfo
        self.custom = custom
        self.generation = generation
    }
}

// MARK: - Peer

/// A discovered peer on the local network.
public struct Peer: Sendable, Identifiable {
    public var id: PeerID
    public let name: String
    public let status: PeerStatus

    public init(id: PeerID, name: String, status: PeerStatus) {
        self.id = id
        self.name = name
        self.status = status
    }
}
