import Testing
import Foundation
@testable import PeerClock

@Suite("MessageCodec")
struct MessageCodecTests {

    @Test("Encode and decode SYNC_REQUEST")
    func syncRequest() throws {
        let t0: UInt64 = 1_000_000_000
        let message = WireMessage(category: .syncRequest, payload: MessageCodec.encodeSyncRequest(t0: t0))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .syncRequest)
        let timestamps = try MessageCodec.decodeSyncRequest(decoded.payload)
        #expect(timestamps == t0)
    }

    @Test("Encode and decode SYNC_RESPONSE")
    func syncResponse() throws {
        let t0: UInt64 = 1_000_000_000
        let t1: UInt64 = 1_000_000_500
        let t2: UInt64 = 1_000_000_600
        let message = WireMessage(category: .syncResponse, payload: MessageCodec.encodeSyncResponse(t0: t0, t1: t1, t2: t2))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .syncResponse)
        let (dt0, dt1, dt2) = try MessageCodec.decodeSyncResponse(decoded.payload)
        #expect(dt0 == t0)
        #expect(dt1 == t1)
        #expect(dt2 == t2)
    }

    @Test("Encode and decode APP_COMMAND")
    func appCommand() throws {
        let cmd = Command(type: "com.test.action", payload: Data([0xAA, 0xBB]))
        let message = WireMessage(category: .appCommand, payload: MessageCodec.encodeCommand(cmd))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .appCommand)
        let decodedCmd = try MessageCodec.decodeCommand(decoded.payload)
        #expect(decodedCmd.type == "com.test.action")
        #expect(decodedCmd.payload == Data([0xAA, 0xBB]))
    }

    @Test("Encode and decode ELECTION")
    func election() throws {
        let peerID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let message = WireMessage(category: .election, payload: MessageCodec.encodeElection(coordinatorID: peerID))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .election)
        let decodedID = try MessageCodec.decodeElection(decoded.payload)
        #expect(decodedID == peerID)
    }

    @Test("Header is 5 bytes: version(1) + category(1) + flags(1) + length(2)")
    func headerSize() {
        let message = WireMessage(category: .heartbeat, payload: Data())
        let data = MessageCodec.encode(message)
        #expect(data.count == 5)
    }

    @Test("Version is 0x01")
    func version() {
        let message = WireMessage(category: .heartbeat, payload: Data())
        let data = MessageCodec.encode(message)
        #expect(data[0] == 0x01)
    }

    @Test("Decode rejects unknown version")
    func unknownVersion() {
        let data = Data([0x02, 0x30, 0x00, 0x00, 0x00])
        #expect(throws: MessageCodecError.self) {
            try MessageCodec.decode(data)
        }
    }

    @Test("Decode rejects truncated data")
    func truncatedData() {
        let data = Data([0x01, 0x01])
        #expect(throws: MessageCodecError.self) {
            try MessageCodec.decode(data)
        }
    }
}
