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

    // MARK: - Error path tests (I-4)

    @Test func decodeIncompleteHeaderReturnsNil() throws {
        // 1-byte data is not enough for a header (need at least 2)
        let data = Data([0x81])
        let result = try WebSocketFrame.decode(data)
        #expect(result == nil)
    }

    @Test func decodeIncompletePayloadReturnsNil() throws {
        // Header says payload length=5, but only 3 bytes provided
        // FIN=1, opcode=text(1), unmasked, len=5
        let bytes: [UInt8] = [0x81, 0x05, 0x68, 0x65, 0x6C]  // "hel" (3 of 5 bytes)
        let result = try WebSocketFrame.decode(Data(bytes))
        #expect(result == nil)
    }

    @Test func decodeFragmentedFrameThrows() throws {
        // FIN=0 (continuation frame) should throw fragmentationNotSupported
        // byte0: FIN=0, opcode=text(1) → 0x01
        let bytes: [UInt8] = [0x01, 0x02, 0x68, 0x69]
        #expect(throws: WebSocketFrame.DecodeError.fragmentationNotSupported) {
            try WebSocketFrame.decode(Data(bytes))
        }
    }

    @Test func decodeUnsupportedOpcodeThrows() throws {
        // opcode=0x3 is reserved/unsupported
        // byte0: FIN=1, opcode=3 → 0x83
        let bytes: [UInt8] = [0x83, 0x00]
        #expect(throws: WebSocketFrame.DecodeError.unsupportedOpcode(0x3)) {
            try WebSocketFrame.decode(Data(bytes))
        }
    }

    @Test func decodeReservedBitsSetThrows() throws {
        // RSV1=1 (bit 6 of byte0 set) → byte0 = 0x81 | 0x40 = 0xC1
        // FIN=1, RSV1=1, opcode=text(1)
        let bytes: [UInt8] = [0xC1, 0x02, 0x68, 0x69]
        #expect(throws: WebSocketFrame.DecodeError.reservedBitsSet) {
            try WebSocketFrame.decode(Data(bytes))
        }
    }

    @Test func decodeControlFrameTooLargeThrows() throws {
        // Close frame (opcode=0x8) with 126-byte payload → should throw controlFrameTooLarge
        // Manually construct: FIN=1, opcode=0x8, payload_len marker=126 (extended 16-bit)
        // byte0=0x88, byte1=0x7E (126 marker), then 2-byte length = 126
        var bytes: [UInt8] = [0x88, 0x7E, 0x00, 0x7E]  // header with 16-bit len=126
        bytes.append(contentsOf: [UInt8](repeating: 0x41, count: 126))  // 126 bytes of 'A'
        #expect(throws: WebSocketFrame.DecodeError.controlFrameTooLarge) {
            try WebSocketFrame.decode(Data(bytes))
        }
    }

    @Test func roundTripEmptyTextFrame() throws {
        // Encode empty string, decode, expect empty string back
        let encoded = WebSocketFrame.encode(text: "", masked: false)
        let (frame, consumed) = try WebSocketFrame.decode(encoded)!
        #expect(consumed == encoded.count)
        if case .text(let s) = frame {
            #expect(s == "")
        } else {
            Issue.record("Expected .text, got \(frame)")
        }
    }

    @Test func roundTripExtended64BitPayload() throws {
        // 65536-byte payload forces 8-byte extended length encoding
        let payloadSize = 65536
        let originalData = Data(repeating: 0xAB, count: payloadSize)
        let encoded = WebSocketFrame.encode(binary: originalData, masked: false)

        // Verify 8-byte length encoding: byte1 should be 127 (0x7F)
        #expect(encoded[1] == 0x7F)
        // Total size: 1 (byte0) + 1 (byte1) + 8 (extended len) + 65536 (payload)
        #expect(encoded.count == 1 + 1 + 8 + payloadSize)

        let (frame, consumed) = try WebSocketFrame.decode(encoded)!
        #expect(consumed == encoded.count)
        if case .binary(let data) = frame {
            #expect(data == originalData)
        } else {
            Issue.record("Expected .binary, got \(frame)")
        }
    }
}
