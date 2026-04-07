import Foundation

public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }

    /// Reliable unicast.
    func send(_ data: Data, to peer: PeerID) async throws

    /// Reliable broadcast. Used by STATUS_PUSH and other order-sensitive traffic.
    func broadcast(_ data: Data) async throws

    /// Unreliable broadcast. Used by HEARTBEAT.
    /// WiFiTransport currently aliases this to `broadcast` (TCP); Phase 3 will
    /// add a real UDP path. MockTransport may record the call separately for
    /// tests that need to distinguish channels.
    func broadcastUnreliable(_ data: Data) async throws
}

public extension Transport {
    /// Default: fall back to reliable broadcast. WiFiTransport relies on this.
    func broadcastUnreliable(_ data: Data) async throws {
        try await broadcast(data)
    }
}
