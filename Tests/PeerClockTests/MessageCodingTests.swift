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
}
