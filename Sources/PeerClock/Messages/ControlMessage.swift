import Foundation

/// Control-plane messages exchanged between host and clients over WebSocket.
/// Uses `type` discriminator for tagged-union JSON encoding.
public enum ControlMessage: Codable, Equatable, Sendable {
    case sessionInit(
        sessionID: UUID,
        term: UInt64,
        sessionGeneration: UInt64,
        hostPeerID: PeerID,
        timeBaseNs: UInt64
    )
    case startRecording(
        targetTimeNs: UInt64,
        preset: String,
        sessionID: UUID,
        commandID: UUID,
        commandVersion: UInt64
    )
    case stopRecording(
        atTimeNs: UInt64,
        sessionID: UUID,
        commandID: UUID,
        commandVersion: UInt64
    )
    case heartbeat(hostTimeNs: UInt64, term: UInt64)
    case status(
        peerID: PeerID,
        state: String,
        elapsedSeconds: Int?,
        preset: String?
    )
    case recordingAck(
        sessionID: UUID,
        peerID: PeerID,
        localStartNs: UInt64
    )

    private enum CodingKeys: String, CodingKey { case type, payload }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sessionInit(let s, let t, let g, let h, let b):
            try container.encode("session_init", forKey: .type)
            try container.encode(SessionInitPayload(sessionID: s, term: t, sessionGeneration: g, hostPeerID: h, timeBaseNs: b), forKey: .payload)
        case .startRecording(let t, let p, let s, let c, let v):
            try container.encode("start_recording", forKey: .type)
            try container.encode(StartRecordingPayload(targetTimeNs: t, preset: p, sessionID: s, commandID: c, commandVersion: v), forKey: .payload)
        case .stopRecording(let t, let s, let c, let v):
            try container.encode("stop_recording", forKey: .type)
            try container.encode(StopRecordingPayload(atTimeNs: t, sessionID: s, commandID: c, commandVersion: v), forKey: .payload)
        case .heartbeat(let t, let term):
            try container.encode("heartbeat", forKey: .type)
            try container.encode(HeartbeatPayload(hostTimeNs: t, term: term), forKey: .payload)
        case .status(let p, let state, let e, let preset):
            try container.encode("status", forKey: .type)
            try container.encode(StatusPayload(peerID: p, state: state, elapsedSeconds: e, preset: preset), forKey: .payload)
        case .recordingAck(let s, let p, let l):
            try container.encode("recording_ack", forKey: .type)
            try container.encode(RecordingAckPayload(sessionID: s, peerID: p, localStartNs: l), forKey: .payload)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "session_init":
            let p = try container.decode(SessionInitPayload.self, forKey: .payload)
            self = .sessionInit(sessionID: p.sessionID, term: p.term, sessionGeneration: p.sessionGeneration, hostPeerID: p.hostPeerID, timeBaseNs: p.timeBaseNs)
        case "start_recording":
            let p = try container.decode(StartRecordingPayload.self, forKey: .payload)
            self = .startRecording(targetTimeNs: p.targetTimeNs, preset: p.preset, sessionID: p.sessionID, commandID: p.commandID, commandVersion: p.commandVersion)
        case "stop_recording":
            let p = try container.decode(StopRecordingPayload.self, forKey: .payload)
            self = .stopRecording(atTimeNs: p.atTimeNs, sessionID: p.sessionID, commandID: p.commandID, commandVersion: p.commandVersion)
        case "heartbeat":
            let p = try container.decode(HeartbeatPayload.self, forKey: .payload)
            self = .heartbeat(hostTimeNs: p.hostTimeNs, term: p.term)
        case "status":
            let p = try container.decode(StatusPayload.self, forKey: .payload)
            self = .status(peerID: p.peerID, state: p.state, elapsedSeconds: p.elapsedSeconds, preset: p.preset)
        case "recording_ack":
            let p = try container.decode(RecordingAckPayload.self, forKey: .payload)
            self = .recordingAck(sessionID: p.sessionID, peerID: p.peerID, localStartNs: p.localStartNs)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }
}

// Payload structs (private)
private struct SessionInitPayload: Codable, Equatable {
    let sessionID: UUID
    let term: UInt64
    let sessionGeneration: UInt64
    let hostPeerID: PeerID
    let timeBaseNs: UInt64
}
private struct StartRecordingPayload: Codable, Equatable {
    let targetTimeNs: UInt64
    let preset: String
    let sessionID: UUID
    let commandID: UUID
    let commandVersion: UInt64
}
private struct StopRecordingPayload: Codable, Equatable {
    let atTimeNs: UInt64
    let sessionID: UUID
    let commandID: UUID
    let commandVersion: UInt64
}
private struct HeartbeatPayload: Codable, Equatable {
    let hostTimeNs: UInt64
    let term: UInt64
}
private struct StatusPayload: Codable, Equatable {
    let peerID: PeerID
    let state: String
    let elapsedSeconds: Int?
    let preset: String?
}
private struct RecordingAckPayload: Codable, Equatable {
    let sessionID: UUID
    let peerID: PeerID
    let localStartNs: UInt64
}
