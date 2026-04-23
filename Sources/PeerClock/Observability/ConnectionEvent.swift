import Foundation

/// Public observability event emitted on a ``PeerClock`` instance's
/// ``PeerClock/connectionEvents`` stream. Consumers can aggregate these for
/// analytics or surface them in UI (e.g. "DAWSync handshake failed —
/// invalidUpgrade").
///
/// Producers live in ``StarClient``, ``StarHost``, and ``StarTransport``;
/// events flow up through the topology runtime into the facade. Mesh
/// topology emits nothing on this stream.
public struct ConnectionEvent: Sendable, Equatable {

    public enum HandshakeFailure: Sendable, Equatable {
        case invalidUpgrade
        case badAcceptHash
        case oversizedFrame
        case invalidPayload
    }

    public enum Reason: Sendable, Equatable {
        case handshakeFailed(HandshakeFailure)
        case timeout
        case rejected(reason: String)
        case disconnected(peer: PeerID)
    }

    public let at: Date
    public let reason: Reason
    public let peer: PeerID?

    public init(at: Date = Date(), reason: Reason, peer: PeerID? = nil) {
        self.at = at
        self.reason = reason
        self.peer = peer
    }
}
