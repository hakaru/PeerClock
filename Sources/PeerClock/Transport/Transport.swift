import Foundation

/// Abstraction over the network transport layer.
///
/// Implementations include `WiFiTransport`, `MultipeerTransport`, and
/// `MockTransport`.
public protocol Transport: Sendable {
    /// Starts listening and advertising on the network.
    func start() async throws
    /// Stops all network activity and disconnects peers.
    func stop() async
    /// Stream of currently connected peer ID sets.
    var peers: AsyncStream<Set<PeerID>> { get }
    /// Stream of incoming raw messages from peers.
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }

    /// Broadcasts data reliably to all connected peers.
    ///
    /// Since v0.4.0 (Q5:B), transport-level unicast is removed. All reliable
    /// delivery is broadcast; recipient filtering is an application / router
    /// concern (see `CommandRouter` for commandID/logicalVersion dedup).
    func broadcast(_ data: Data) async throws

    /// Broadcasts data via the unreliable (UDP) channel.
    ///
    /// The default implementation falls back to `broadcast(_:)`.
    func broadcastUnreliable(_ data: Data) async throws
}

public extension Transport {
    /// Default: fall back to reliable broadcast. WiFiTransport relies on this.
    func broadcastUnreliable(_ data: Data) async throws {
        try await broadcast(data)
    }
}
