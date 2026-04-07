import Foundation
import Testing
@testable import PeerClock

@Suite("MessageCodec")
struct MessageCodecTests {

    private let peerID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    @Test("HELLO round-trips")
    func helloRoundTrip() throws {
        let decoded = try roundTrip(.hello(peerID: peerID, protocolVersion: 1))
        #expect(decoded == .hello(peerID: peerID, protocolVersion: 1))
    }

    @Test("PING round-trips")
    func pingRoundTrip() throws {
        let decoded = try roundTrip(.ping(peerID: peerID, t0: 123))
        #expect(decoded == .ping(peerID: peerID, t0: 123))
    }

    @Test("PONG round-trips")
    func pongRoundTrip() throws {
        let decoded = try roundTrip(.pong(peerID: peerID, t0: 1, t1: 2, t2: 3))
        #expect(decoded == .pong(peerID: peerID, t0: 1, t1: 2, t2: 3))
    }

    @Test("COMMAND_BROADCAST round-trips")
    func commandBroadcastRoundTrip() throws {
        let message = Message.commandBroadcast(Command(type: "broadcast", payload: Data([0xAA, 0xBB])))
        let decoded = try roundTrip(message)
        #expect(decoded == message)
    }

    @Test("COMMAND_UNICAST round-trips")
    func commandUnicastRoundTrip() throws {
        let message = Message.commandUnicast(Command(type: "unicast", payload: Data([0x10, 0x20])))
        let decoded = try roundTrip(message)
        #expect(decoded == message)
    }

    @Test("HEARTBEAT round-trips")
    func heartbeatRoundTrip() throws {
        let decoded = try roundTrip(.heartbeat)
        #expect(decoded == .heartbeat)
    }

    @Test("DISCONNECT round-trips")
    func disconnectRoundTrip() throws {
        let decoded = try roundTrip(.disconnect)
        #expect(decoded == .disconnect)
    }

    @Test("Header is 5 bytes")
    func headerSize() {
        let encoded = MessageCodec.encode(.heartbeat)
        #expect(encoded.count == 5)
        #expect(encoded[0] == 0x01)
        #expect(encoded[1] == 0x20)
        #expect(encoded[2] == 0x00)
        #expect(encoded[3] == 0x00)
        #expect(encoded[4] == 0x00)
    }

    @Test("Decode rejects unsupported version")
    func unsupportedVersion() {
        let encoded = Data([0x02, 0x20, 0x00, 0x00, 0x00])
        #expect(throws: MessageCodecError.self) {
            try MessageCodec.decode(encoded)
        }
    }

    @Test("Decode rejects truncated frames")
    func truncatedFrame() {
        let encoded = Data([0x01, 0x02, 0x00, 0x18, 0x00])
        #expect(throws: MessageCodecError.self) {
            try MessageCodec.decode(encoded)
        }
    }

    private func roundTrip(_ message: Message) throws -> Message {
        try MessageCodec.decode(MessageCodec.encode(message))
    }
}
