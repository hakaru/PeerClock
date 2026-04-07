import Foundation

/// P2P clock synchronization for Apple devices on a local network.
///
/// PeerClock enables multiple devices to agree on a shared time reference
/// within ±2ms, without requiring an external server or internet connection.
/// All peers are equal — there is no master/slave distinction.
///
/// ```swift
/// let clock = PeerClock()
/// clock.start()
///
/// let now = clock.now  // Agrees across all devices (±2ms)
/// ```
public final class PeerClock: Sendable {

    /// Library version.
    public static let version = "0.2.0"

    /// Initialize PeerClock with an optional configuration.
    /// - Parameter configuration: Runtime settings. Defaults to `Configuration.default`.
    public init(configuration: Configuration = .default) {
        // TODO: Phase 2 implementation
    }
}
