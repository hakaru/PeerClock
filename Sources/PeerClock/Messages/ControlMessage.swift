import Foundation

/// Control-plane messages exchanged between host and clients over WebSocket.
/// Uses `type` discriminator for tagged-union JSON encoding.
///
/// **Wire boundary note:**
/// These messages are JSON-encoded and transmitted over the WebSocket-based
/// `StarTransport` introduced in v0.3. They are **not** compatible with the
/// binary `Message` type in `Wire/Message.swift`, which belongs exclusively to
/// the legacy `MultipeerTransport` protocol. Do not mix the two on the same wire.
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
        commandVersion: UInt64,
        term: UInt64,
        sessionGeneration: UInt64
    )
    case stopRecording(
        atTimeNs: UInt64,
        sessionID: UUID,
        commandID: UUID,
        commandVersion: UInt64,
        term: UInt64,
        sessionGeneration: UInt64
    )
    case heartbeat(hostTimeNs: UInt64, term: UInt64)
    // TODO(v0.3): consider strongly-typed enums for `state` and `preset`
    // once the consuming layers are wired up.
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
        case .sessionInit(let sessionID, let term, let sessionGeneration, let hostPeerID, let timeBaseNs):
            try container.encode("session_init", forKey: .type)
            try container.encode(SessionInitPayload(sessionID: sessionID, term: term, sessionGeneration: sessionGeneration, hostPeerID: hostPeerID, timeBaseNs: timeBaseNs), forKey: .payload)
        case .startRecording(let targetTimeNs, let preset, let sessionID, let commandID, let commandVersion, let term, let sessionGeneration):
            try container.encode("start_recording", forKey: .type)
            try container.encode(StartRecordingPayload(targetTimeNs: targetTimeNs, preset: preset, sessionID: sessionID, commandID: commandID, commandVersion: commandVersion, term: term, sessionGeneration: sessionGeneration), forKey: .payload)
        case .stopRecording(let atTimeNs, let sessionID, let commandID, let commandVersion, let term, let sessionGeneration):
            try container.encode("stop_recording", forKey: .type)
            try container.encode(StopRecordingPayload(atTimeNs: atTimeNs, sessionID: sessionID, commandID: commandID, commandVersion: commandVersion, term: term, sessionGeneration: sessionGeneration), forKey: .payload)
        case .heartbeat(let hostTimeNs, let term):
            try container.encode("heartbeat", forKey: .type)
            try container.encode(HeartbeatPayload(hostTimeNs: hostTimeNs, term: term), forKey: .payload)
        case .status(let peerID, let state, let elapsedSeconds, let preset):
            try container.encode("status", forKey: .type)
            try container.encode(StatusPayload(peerID: peerID, state: state, elapsedSeconds: elapsedSeconds, preset: preset), forKey: .payload)
        case .recordingAck(let sessionID, let peerID, let localStartNs):
            try container.encode("recording_ack", forKey: .type)
            try container.encode(RecordingAckPayload(sessionID: sessionID, peerID: peerID, localStartNs: localStartNs), forKey: .payload)
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
            self = .startRecording(targetTimeNs: p.targetTimeNs, preset: p.preset, sessionID: p.sessionID, commandID: p.commandID, commandVersion: p.commandVersion, term: p.term, sessionGeneration: p.sessionGeneration)
        case "stop_recording":
            let p = try container.decode(StopRecordingPayload.self, forKey: .payload)
            self = .stopRecording(atTimeNs: p.atTimeNs, sessionID: p.sessionID, commandID: p.commandID, commandVersion: p.commandVersion, term: p.term, sessionGeneration: p.sessionGeneration)
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
private struct SessionInitPayload: Codable {
    let sessionID: UUID
    let term: UInt64
    let sessionGeneration: UInt64
    let hostPeerID: PeerID
    let timeBaseNs: UInt64
}
private struct StartRecordingPayload: Codable {
    let targetTimeNs: UInt64
    let preset: String
    let sessionID: UUID
    let commandID: UUID
    let commandVersion: UInt64
    let term: UInt64
    let sessionGeneration: UInt64
}
private struct StopRecordingPayload: Codable {
    let atTimeNs: UInt64
    let sessionID: UUID
    let commandID: UUID
    let commandVersion: UInt64
    let term: UInt64
    let sessionGeneration: UInt64
}
private struct HeartbeatPayload: Codable {
    let hostTimeNs: UInt64
    let term: UInt64
}
private struct StatusPayload: Codable {
    let peerID: PeerID
    let state: String
    let elapsedSeconds: Int?
    let preset: String?
}
private struct RecordingAckPayload: Codable {
    let sessionID: UUID
    let peerID: PeerID
    let localStartNs: UInt64
}
