import Testing
import Foundation
@testable import PeerClock

@Suite("ControlMessage coding")
struct ControlMessageCodingTests {

    @Test func sessionInitRoundTrip() throws {
        let msg = ControlMessage.sessionInit(
            sessionID: UUID(),
            term: 42,
            sessionGeneration: 7,
            hostPeerID: PeerID(UUID()),
            timeBaseNs: 12345
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func startRecordingRoundTrip() throws {
        let msg = ControlMessage.startRecording(
            targetTimeNs: 99999,
            preset: "studio_heavy",
            sessionID: UUID(),
            commandID: UUID(),
            commandVersion: 1
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func stopRecordingRoundTrip() throws {
        let msg = ControlMessage.stopRecording(
            atTimeNs: 555000,
            sessionID: UUID(),
            commandID: UUID(),
            commandVersion: 2
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func heartbeatRoundTrip() throws {
        let msg = ControlMessage.heartbeat(hostTimeNs: 8888888, term: 3)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func statusWithElapsedSecondsRoundTrip() throws {
        let msg = ControlMessage.status(
            peerID: PeerID(UUID()),
            state: "recording",
            elapsedSeconds: 42,
            preset: "studio_heavy"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func statusWithNilElapsedSecondsRoundTrip() throws {
        let msg = ControlMessage.status(
            peerID: PeerID(UUID()),
            state: "idle",
            elapsedSeconds: nil,
            preset: nil
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func recordingAckRoundTrip() throws {
        let msg = ControlMessage.recordingAck(
            sessionID: UUID(),
            peerID: PeerID(UUID()),
            localStartNs: 123456789
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ControlMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func unknownTypeThrows() throws {
        let json = """
        {"type":"unknown_future_type","payload":{}}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ControlMessage.self, from: json)
        }
    }
}

@Suite("NtpMessage coding")
struct NtpMessageCodingTests {

    @Test func pingRoundTrip() throws {
        let msg = NtpMessage.ping(t0: 1_000_000, peerID: PeerID(UUID()))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(NtpMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func pongRoundTrip() throws {
        let msg = NtpMessage.pong(
            t0: 1_000_000,
            t1: 2_000_000,
            t2: 3_000_000,
            hostPeerID: PeerID(UUID())
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(NtpMessage.self, from: data)
        #expect(decoded == msg)
    }

    @Test func unknownTypeThrows() throws {
        let json = """
        {"type":"ntp_unknown","payload":{}}
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NtpMessage.self, from: json)
        }
    }
}
