import Foundation

/// NTP-style ping/pong messages. Separate from ControlMessage to allow
/// independent queueing for timestamp precision (see spec §8.3).
public enum NtpMessage: Codable, Equatable, Sendable {
    case ping(t0: UInt64, peerID: PeerID)
    case pong(t0: UInt64, t1: UInt64, t2: UInt64, hostPeerID: PeerID)

    private enum CodingKeys: String, CodingKey { case type, payload }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ping(let t0, let p):
            try container.encode("ntp_ping", forKey: .type)
            try container.encode(PingPayload(t0: t0, peerID: p), forKey: .payload)
        case .pong(let t0, let t1, let t2, let h):
            try container.encode("ntp_pong", forKey: .type)
            try container.encode(PongPayload(t0: t0, t1: t1, t2: t2, hostPeerID: h), forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ntp_ping":
            let p = try container.decode(PingPayload.self, forKey: .payload)
            self = .ping(t0: p.t0, peerID: p.peerID)
        case "ntp_pong":
            let p = try container.decode(PongPayload.self, forKey: .payload)
            self = .pong(t0: p.t0, t1: p.t1, t2: p.t2, hostPeerID: p.hostPeerID)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }
}

private struct PingPayload: Codable, Equatable {
    let t0: UInt64
    let peerID: PeerID
}
private struct PongPayload: Codable, Equatable {
    let t0: UInt64
    let t1: UInt64
    let t2: UInt64
    let hostPeerID: PeerID
}
