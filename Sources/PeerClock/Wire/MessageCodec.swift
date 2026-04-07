import Foundation

// MARK: - MessageCategory

/// Wire protocol message category byte.
public enum MessageCategory: UInt8, Sendable {
    case syncRequest    = 0x01
    case syncResponse   = 0x02
    case heartbeat      = 0x10
    case disconnect     = 0x11
    case election       = 0x12
    case appCommand     = 0x20
    case statusPush     = 0x30
    case statusRequest  = 0x31
    case statusResponse = 0x32
}

// MARK: - WireMessage

/// A decoded wire-protocol message.
public struct WireMessage: Sendable {
    public let category: MessageCategory
    public let flags: UInt8
    public let payload: Data

    public init(category: MessageCategory, flags: UInt8 = 0x00, payload: Data) {
        self.category = category
        self.flags = flags
        self.payload = payload
    }
}

// MARK: - MessageCodecError

/// Errors thrown during wire-protocol decoding.
public enum MessageCodecError: Error, Sendable {
    case truncatedData
    case unsupportedVersion(UInt8)
    case unknownCategory(UInt8)
    case invalidPayload
}

// MARK: - MessageCodec

/// Namespace for wire-protocol encode / decode operations.
///
/// Frame layout (header = 5 bytes):
/// ```
/// ┌─────────┬──────────┬──────────┬──────────┬─────────────┐
/// │ Version │ Category │ Flags    │ Length   │ Payload     │
/// │ 1 byte  │ 1 byte   │ 1 byte   │ 2 bytes  │ N bytes     │
/// └─────────┴──────────┴──────────┴──────────┴─────────────┘
/// ```
/// All multi-byte integers are big-endian.
public enum MessageCodec {

    private static let version: UInt8 = 0x01
    private static let headerSize = 5

    // MARK: Frame encode / decode

    /// Encode a `WireMessage` into a framed byte buffer.
    public static func encode(_ message: WireMessage) -> Data {
        let payloadLength = UInt16(message.payload.count)
        var data = Data(capacity: headerSize + message.payload.count)
        data.append(version)
        data.append(message.category.rawValue)
        data.append(message.flags)
        // Length: big-endian UInt16
        data.append(UInt8((payloadLength >> 8) & 0xFF))
        data.append(UInt8(payloadLength & 0xFF))
        data.append(contentsOf: message.payload)
        return data
    }

    /// Decode a framed byte buffer into a `WireMessage`.
    public static func decode(_ data: Data) throws -> WireMessage {
        guard data.count >= headerSize else {
            throw MessageCodecError.truncatedData
        }

        let ver = data[data.startIndex]
        guard ver == version else {
            throw MessageCodecError.unsupportedVersion(ver)
        }

        let categoryByte = data[data.startIndex + 1]
        guard let category = MessageCategory(rawValue: categoryByte) else {
            throw MessageCodecError.unknownCategory(categoryByte)
        }

        let flags = data[data.startIndex + 2]
        let lengthHigh = UInt16(data[data.startIndex + 3])
        let lengthLow  = UInt16(data[data.startIndex + 4])
        let payloadLength = Int((lengthHigh << 8) | lengthLow)

        let payloadStart = data.startIndex + headerSize
        let payloadEnd   = payloadStart + payloadLength

        guard data.count >= headerSize + payloadLength else {
            throw MessageCodecError.truncatedData
        }

        let payload = data[payloadStart..<payloadEnd]
        return WireMessage(category: category, flags: flags, payload: Data(payload))
    }

    // MARK: SYNC_REQUEST helpers (8 bytes: t0 big-endian UInt64)

    public static func encodeSyncRequest(t0: UInt64) -> Data {
        return encodeUInt64(t0)
    }

    public static func decodeSyncRequest(_ payload: Data) throws -> UInt64 {
        guard payload.count >= 8 else { throw MessageCodecError.invalidPayload }
        return decodeUInt64(payload, offset: 0)
    }

    // MARK: SYNC_RESPONSE helpers (24 bytes: t0, t1, t2 big-endian UInt64)

    public static func encodeSyncResponse(t0: UInt64, t1: UInt64, t2: UInt64) -> Data {
        var data = Data(capacity: 24)
        data.append(contentsOf: encodeUInt64(t0))
        data.append(contentsOf: encodeUInt64(t1))
        data.append(contentsOf: encodeUInt64(t2))
        return data
    }

    public static func decodeSyncResponse(_ payload: Data) throws -> (t0: UInt64, t1: UInt64, t2: UInt64) {
        guard payload.count >= 24 else { throw MessageCodecError.invalidPayload }
        let t0 = decodeUInt64(payload, offset: 0)
        let t1 = decodeUInt64(payload, offset: 8)
        let t2 = decodeUInt64(payload, offset: 16)
        return (t0, t1, t2)
    }

    // MARK: APP_COMMAND helpers
    // Layout: typeLen(2 bytes BE) + type(UTF-8) + payload(rest)

    public static func encodeCommand(_ command: Command) -> Data {
        let typeBytes = Data(command.type.utf8)
        let typeLen = UInt16(typeBytes.count)
        var data = Data(capacity: 2 + typeBytes.count + command.payload.count)
        data.append(UInt8((typeLen >> 8) & 0xFF))
        data.append(UInt8(typeLen & 0xFF))
        data.append(contentsOf: typeBytes)
        data.append(contentsOf: command.payload)
        return data
    }

    public static func decodeCommand(_ payload: Data) throws -> Command {
        guard payload.count >= 2 else { throw MessageCodecError.invalidPayload }
        let high = UInt16(payload[payload.startIndex])
        let low  = UInt16(payload[payload.startIndex + 1])
        let typeLen = Int((high << 8) | low)
        guard payload.count >= 2 + typeLen else { throw MessageCodecError.invalidPayload }
        let typeData = payload[(payload.startIndex + 2)..<(payload.startIndex + 2 + typeLen)]
        guard let typeString = String(bytes: typeData, encoding: .utf8) else {
            throw MessageCodecError.invalidPayload
        }
        let cmdPayload = Data(payload[(payload.startIndex + 2 + typeLen)...])
        return Command(type: typeString, payload: cmdPayload)
    }

    // MARK: ELECTION helpers (16 bytes UUID)

    public static func encodeElection(coordinatorID: PeerID) -> Data {
        return uuidToData(coordinatorID.rawValue)
    }

    public static func decodeElection(_ payload: Data) throws -> PeerID {
        guard payload.count >= 16 else { throw MessageCodecError.invalidPayload }
        let uuid = try dataToUUID(payload)
        return PeerID(uuid)
    }

    // MARK: Private helpers

    private static func encodeUInt64(_ value: UInt64) -> Data {
        var data = Data(count: 8)
        data[0] = UInt8((value >> 56) & 0xFF)
        data[1] = UInt8((value >> 48) & 0xFF)
        data[2] = UInt8((value >> 40) & 0xFF)
        data[3] = UInt8((value >> 32) & 0xFF)
        data[4] = UInt8((value >> 24) & 0xFF)
        data[5] = UInt8((value >> 16) & 0xFF)
        data[6] = UInt8((value >>  8) & 0xFF)
        data[7] = UInt8( value        & 0xFF)
        return data
    }

    private static func decodeUInt64(_ data: Data, offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        return UInt64(data[base + 0]) << 56
             | UInt64(data[base + 1]) << 48
             | UInt64(data[base + 2]) << 40
             | UInt64(data[base + 3]) << 32
             | UInt64(data[base + 4]) << 24
             | UInt64(data[base + 5]) << 16
             | UInt64(data[base + 6]) <<  8
             | UInt64(data[base + 7])
    }

    private static func uuidToData(_ uuid: UUID) -> Data {
        var data = Data(count: 16)
        let t = uuid.uuid
        data[ 0] = t.0;  data[ 1] = t.1;  data[ 2] = t.2;  data[ 3] = t.3
        data[ 4] = t.4;  data[ 5] = t.5;  data[ 6] = t.6;  data[ 7] = t.7
        data[ 8] = t.8;  data[ 9] = t.9;  data[10] = t.10; data[11] = t.11
        data[12] = t.12; data[13] = t.13; data[14] = t.14; data[15] = t.15
        return data
    }

    private static func dataToUUID(_ data: Data) throws -> UUID {
        guard data.count >= 16 else { throw MessageCodecError.invalidPayload }
        let b = data.startIndex
        let t = (
            data[b],     data[b+1],  data[b+2],  data[b+3],
            data[b+4],   data[b+5],  data[b+6],  data[b+7],
            data[b+8],   data[b+9],  data[b+10], data[b+11],
            data[b+12],  data[b+13], data[b+14], data[b+15]
        )
        return UUID(uuid: t)
    }
}
