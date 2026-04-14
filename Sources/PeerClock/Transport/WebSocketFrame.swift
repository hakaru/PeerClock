import Foundation

/// Minimal RFC 6455 WebSocket frame codec. Supports text/binary/close/ping/pong.
/// Does not fragment (all frames have FIN=1). Payload limit: 2^63 - 1 bytes.
public enum WebSocketFrame: Equatable {
    case text(String)
    case binary(Data)
    case close(code: UInt16, reason: String)
    case ping(Data)
    case pong(Data)

    public enum DecodeError: Error, Equatable {
        case incompleteHeader
        case incompletePayload
        case invalidUTF8
        case unsupportedOpcode(UInt8)
        case fragmentationNotSupported
    }

    /// Encode a text frame. Clients must set masked=true (RFC 6455 §5.3).
    public static func encode(text: String, masked: Bool) -> Data {
        return encode(opcode: 0x1, payload: Data(text.utf8), masked: masked)
    }

    public static func encode(binary: Data, masked: Bool) -> Data {
        return encode(opcode: 0x2, payload: binary, masked: masked)
    }

    public static func encodeClose(code: UInt16, reason: String, masked: Bool) -> Data {
        var payload = Data()
        payload.append(UInt8(code >> 8))
        payload.append(UInt8(code & 0xFF))
        payload.append(Data(reason.utf8))
        return encode(opcode: 0x8, payload: payload, masked: masked)
    }

    public static func encodePing(_ payload: Data = Data(), masked: Bool) -> Data {
        return encode(opcode: 0x9, payload: payload, masked: masked)
    }

    public static func encodePong(_ payload: Data, masked: Bool) -> Data {
        return encode(opcode: 0xA, payload: payload, masked: masked)
    }

    private static func encode(opcode: UInt8, payload: Data, masked: Bool) -> Data {
        var out = Data()
        out.append(0x80 | opcode)  // FIN=1 + opcode

        let len = payload.count
        let maskBit: UInt8 = masked ? 0x80 : 0

        if len < 126 {
            out.append(UInt8(len) | maskBit)
        } else if len <= 0xFFFF {
            out.append(126 | maskBit)
            out.append(UInt8(len >> 8))
            out.append(UInt8(len & 0xFF))
        } else {
            out.append(127 | maskBit)
            for i in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((len >> i) & 0xFF))
            }
        }

        if masked {
            var key = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &key)
            out.append(contentsOf: key)
            let maskedPayload = zip(payload, (0..<payload.count).map { key[$0 % 4] }).map { $0 ^ $1 }
            out.append(contentsOf: maskedPayload)
        } else {
            out.append(payload)
        }

        return out
    }

    /// Decode a single frame from the start of `data`. Returns the frame and
    /// the number of bytes consumed. Returns nil if not enough data yet.
    public static func decode(_ data: Data) throws -> (frame: WebSocketFrame, consumed: Int)? {
        guard data.count >= 2 else { return nil }

        let byte0 = data[data.startIndex]
        let byte1 = data[data.startIndex + 1]

        let fin = (byte0 & 0x80) != 0
        let opcode = byte0 & 0x0F

        guard fin else { throw DecodeError.fragmentationNotSupported }

        let masked = (byte1 & 0x80) != 0
        let payloadLenByte = byte1 & 0x7F

        var offset = 2
        let payloadLen: Int

        if payloadLenByte < 126 {
            payloadLen = Int(payloadLenByte)
        } else if payloadLenByte == 126 {
            guard data.count >= offset + 2 else { return nil }
            payloadLen = (Int(data[data.startIndex + offset]) << 8) | Int(data[data.startIndex + offset + 1])
            offset += 2
        } else {
            guard data.count >= offset + 8 else { return nil }
            var len: UInt64 = 0
            for i in 0..<8 {
                len = (len << 8) | UInt64(data[data.startIndex + offset + i])
            }
            payloadLen = Int(len)
            offset += 8
        }

        var maskKey: [UInt8]? = nil
        if masked {
            guard data.count >= offset + 4 else { return nil }
            maskKey = (0..<4).map { data[data.startIndex + offset + $0] }
            offset += 4
        }

        guard data.count >= offset + payloadLen else { return nil }

        let rawPayload = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + payloadLen))
        let payload: Data
        if let key = maskKey {
            payload = Data(zip(rawPayload, (0..<rawPayload.count).map { key[$0 % 4] }).map { $0 ^ $1 })
        } else {
            payload = rawPayload
        }

        let frame: WebSocketFrame
        switch opcode {
        case 0x1:
            guard let s = String(data: payload, encoding: .utf8) else { throw DecodeError.invalidUTF8 }
            frame = .text(s)
        case 0x2:
            frame = .binary(payload)
        case 0x8:
            let code: UInt16 = payload.count >= 2 ? (UInt16(payload[payload.startIndex]) << 8) | UInt16(payload[payload.startIndex + 1]) : 1000
            let reason = payload.count > 2 ? (String(data: payload.subdata(in: (payload.startIndex + 2)..<payload.endIndex), encoding: .utf8) ?? "") : ""
            frame = .close(code: code, reason: reason)
        case 0x9:
            frame = .ping(payload)
        case 0xA:
            frame = .pong(payload)
        default:
            throw DecodeError.unsupportedOpcode(opcode)
        }

        return (frame, offset + payloadLen)
    }
}
