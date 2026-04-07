// Tests/PeerClockTests/WireStatusTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("Wire — Status messages")
struct WireStatusTests {

    @Test("statusPush round-trip with multiple entries")
    func statusPushRoundTrip() throws {
        let sender = PeerID(rawValue: UUID())
        let entries = [
            StatusEntry(key: "pc.device.name", value: Data("iPhone".utf8)),
            StatusEntry(key: "pc.sync.offset", value: Data([0x01, 0x02, 0x03, 0x04])),
            StatusEntry(key: "", value: Data()),
        ]
        let msg = Message.statusPush(senderID: sender, generation: 42, entries: entries)
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }

    @Test("statusRequest round-trip")
    func statusRequestRoundTrip() throws {
        let sender = PeerID(rawValue: UUID())
        let msg = Message.statusRequest(senderID: sender, correlation: 0xBEEF)
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }

    @Test("statusResponse round-trip")
    func statusResponseRoundTrip() throws {
        let sender = PeerID(rawValue: UUID())
        let entries = [StatusEntry(key: "k", value: Data("v".utf8))]
        let msg = Message.statusResponse(senderID: sender, correlation: 7, generation: 100, entries: entries)
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }

    @Test("statusPush with zero entries")
    func statusPushEmpty() throws {
        let msg = Message.statusPush(senderID: PeerID(rawValue: UUID()), generation: 0, entries: [])
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }
}
