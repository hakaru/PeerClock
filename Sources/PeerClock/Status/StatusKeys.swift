import Foundation

/// Reserved status keys published automatically by PeerClock under the `pc.*` namespace.
public enum StatusKeys {
    /// Current sync offset in nanoseconds (Int64, binary plist encoded).
    public static let syncOffset = "pc.sync.offset"

    /// Current SyncQuality (binary plist encoded).
    public static let syncQuality = "pc.sync.quality"

    /// Human-readable device name (String, binary plist encoded).
    public static let deviceName = "pc.device.name"

    /// Returns true if the given key is in the reserved `pc.*` namespace.
    public static func isReserved(_ key: String) -> Bool {
        key.hasPrefix("pc.")
    }
}
