// PeerClock.swift
// Sub-millisecond P2P clock synchronization between iOS devices

import Foundation

/// P2P clock synchronization for iOS devices on a local network.
///
/// PeerClock enables multiple devices to agree on a shared time reference
/// within ±2ms, without requiring an external server or internet connection.
///
/// ```swift
/// // Master device
/// let clock = PeerClock(role: .master)
/// clock.start()
///
/// // Slave device
/// let clock = PeerClock(role: .slave)
/// clock.join(master: discoveredPeer)
///
/// // Synchronized time
/// let now = clock.now  // Agrees across all devices (±2ms)
/// ```
public final class PeerClock: Sendable {

    /// The role of this device in the sync network.
    public enum Role: Sendable {
        /// Time reference source. Other devices synchronize to this clock.
        case master
        /// Synchronizes its clock to the master device.
        case slave
    }

    /// Current synchronization state.
    public enum State: Sendable {
        /// Not started.
        case idle
        /// Discovering peers / advertising.
        case discovering
        /// Clock sync in progress.
        case syncing
        /// Synchronized and ready.
        case synced(offset: TimeInterval)
        /// Connection lost, attempting recovery.
        case reconnecting
        /// Unrecoverable error.
        case error(String)
    }

    /// Library version.
    public static let version = "0.1.0"

    /// Initialize PeerClock with a role.
    /// - Parameter role: `.master` or `.slave`
    public init(role: Role) {
        // TODO: Phase 1 implementation
    }
}
