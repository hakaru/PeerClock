import Testing
import Foundation
@testable import PeerClock

@Suite("WebSocketFrame")
struct WebSocketFrameTests {

    // MARK: - Basic encode/decode

    @Test func encodeSmallTextFrame() throws {
        let payload = "hello"
        let encoded = WebSocketFrame.encode(text: payload, masked: true)
        // FIN=1, opcode=1 (text), mask=1, len=5 → first byte 0x81, second byte 0x85
        #expect(encoded[0] == 0x81)
        #expect(encoded[1] == 0x85)
        #expect(encoded.count == 2 + 4 + 5)  // header + mask + payload
    }

    @Test func decodeUnmaskedTextFrame() throws {
        // Server-to-client text frame, "hi" (unmasked)
        let bytes: [UInt8] = [0x81, 0x02, 0x68, 0x69]
        let (frame, consumed) = try WebSocketFrame.decode(Data(bytes))!
        #expect(consumed == 4)
        if case .text(let s) = frame {
            #expect(s == "hi")
        } else {
            Issue.record("Expected .text, got \(frame)")
        }
    }

    @Test func roundTripMaskedClientToServer() throws {
        let original = "round-trip test"
        let encoded = WebSocketFrame.encode(text: original, masked: true)
        let (decoded, _) = try WebSocketFrame.decode(encoded)!
        if case .text(let s) = decoded {
            #expect(s == original)
        } else {
            Issue.record("Expected text frame")
        }
    }

    @Test func extendedLength16() throws {
        let payload = String(repeating: "x", count: 200)
        let encoded = WebSocketFrame.encode(text: payload, masked: false)
        // len=200 > 125 → 126 marker + 2-byte length
        #expect(encoded[1] == 0x7E)  // 126
        #expect(encoded.count == 1 + 1 + 2 + 200)
    }

    // MARK: - Control frames (Task 10 expansion)

    @Test func encodeCloseFrame() throws {
        let encoded = WebSocketFrame.encodeClose(code: 1000, reason: "normal", masked: false)
        // FIN=1, opcode=0x8 → first byte 0x88
        #expect(encoded[0] == 0x88)
        // payload = 2 bytes code + 6 bytes "normal" = 8, unmasked → second byte 0x08
        #expect(encoded[1] == 0x08)
        // code 1000 = 0x03E8
        #expect(encoded[2] == 0x03)
        #expect(encoded[3] == 0xE8)
        // reason "normal"
        let reason = String(data: encoded.subdata(in: 4..<encoded.count), encoding: .utf8)
        #expect(reason == "normal")
    }

    @Test func encodePingFrame() throws {
        let encoded = WebSocketFrame.encodePing(Data(), masked: false)
        // FIN=1, opcode=0x9 → first byte 0x89
        #expect(encoded[0] == 0x89)
        // empty payload, unmasked → second byte 0x00
        #expect(encoded[1] == 0x00)
        #expect(encoded.count == 2)
    }

    @Test func encodePongFrame() throws {
        let pingData = Data([0x01, 0x02, 0x03])
        let encoded = WebSocketFrame.encodePong(pingData, masked: false)
        // FIN=1, opcode=0xA → first byte 0x8A
        #expect(encoded[0] == 0x8A)
        // payload length 3, unmasked → second byte 0x03
        #expect(encoded[1] == 0x03)
        #expect(encoded.count == 5)
        #expect(encoded[2] == 0x01)
        #expect(encoded[3] == 0x02)
        #expect(encoded[4] == 0x03)
    }

    @Test func decodePingFrame() throws {
        let pingData = Data("ping-body".utf8)
        let encoded = WebSocketFrame.encodePing(pingData, masked: false)
        let (frame, consumed) = try WebSocketFrame.decode(encoded)!
        #expect(consumed == encoded.count)
        if case .ping(let data) = frame {
            #expect(data == pingData)
        } else {
            Issue.record("Expected .ping, got \(frame)")
        }
    }

    @Test func decodePongFrame() throws {
        let pongData = Data([0xAB, 0xCD])
        let encoded = WebSocketFrame.encodePong(pongData, masked: false)
        let (frame, consumed) = try WebSocketFrame.decode(encoded)!
        #expect(consumed == encoded.count)
        if case .pong(let data) = frame {
            #expect(data == pongData)
        } else {
            Issue.record("Expected .pong, got \(frame)")
        }
    }

    @Test func decodeCloseFrame() throws {
        let encoded = WebSocketFrame.encodeClose(code: 1001, reason: "going away", masked: false)
        let (frame, consumed) = try WebSocketFrame.decode(encoded)!
        #expect(consumed == encoded.count)
        if case .close(let code, let reason) = frame {
            #expect(code == 1001)
            #expect(reason == "going away")
        } else {
            Issue.record("Expected .close, got \(frame)")
        }
    }
}
