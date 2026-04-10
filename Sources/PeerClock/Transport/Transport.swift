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

    /// Sends data reliably to a specific peer.
    func send(_ data: Data, to peer: PeerID) async throws

    /// Broadcasts data reliably to all connected peers.
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
