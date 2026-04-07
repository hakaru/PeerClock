import Foundation

public enum ConnectionEvent: Sendable {
    case peerJoined(PeerID)
    case peerLeft(PeerID)
    case transportDegraded(PeerID)
    case transportRestored(PeerID)
}

public protocol Transport: Sendable {
    func sendUnreliable(_ data: Data, to peer: PeerID) async throws
    var unreliableMessages: AsyncStream<(PeerID, Data)> { get }
    func sendReliable(_ data: Data, to peer: PeerID) async throws
    var reliableMessages: AsyncStream<(PeerID, Data)> { get }
    var connectionEvents: AsyncStream<ConnectionEvent> { get }
    var connectedPeers: [PeerID] { get }
    func broadcastReliable(_ data: Data) async throws
}
