import Foundation

public enum MessageCodecError: Error, Sendable, Equatable {
    case truncatedData
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case invalidLength(Int)
    case invalidPayload
}

public enum MessageCodec {

    private static let version: UInt8 = 0x01
    private static let headerSize = 5

    public static func encode(_ message: Message) -> Data {
        let payload = payload(for: message)
        var data = Data(capacity: headerSize + payload.count)
        data.append(version)
        data.append(message.typeByte)
        data.append(contentsOf: encodeUInt16(UInt16(payload.count)))
        data.append(0x00)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> Message {
        guard data.count >= headerSize else {
            throw MessageCodecError.truncatedData
        }

        let receivedVersion = data[0]
        guard receivedVersion == version else {
            throw MessageCodecError.unsupportedVersion(receivedVersion)
        }

        let type = data[1]
        let payloadLength = Int(decodeUInt16(data, offset: 2))
        guard data.count >= headerSize + payloadLength else {
            throw MessageCodecError.truncatedData
        }
        guard data.count == headerSize + payloadLength else {
            throw MessageCodecError.invalidLength(data.count)
        }

        let payload = Data(data.dropFirst(headerSize))
        switch type {
        case 0x01:
            return try decodeHello(payload)
        case 0x02:
            return try decodePing(payload)
        case 0x03:
            return try decodePong(payload)
        case 0x10:
            return .commandBroadcast(try decodeCommand(payload))
        case 0x11:
            return .commandUnicast(try decodeCommand(payload))
        case 0x20:
            guard payload.isEmpty else { throw MessageCodecError.invalidPayload }
            return .heartbeat
        case 0xFF:
            guard payload.isEmpty else { throw MessageCodecError.invalidPayload }
            return .disconnect
        default:
            throw MessageCodecError.unknownType(type)
        }
    }

    private static func payload(for message: Message) -> Data {
        switch message {
        case .hello(let peerID, let protocolVersion):
            var data = Data()
            data.append(peerID.data)
            data.append(contentsOf: encodeUInt16(protocolVersion))
            return data
        case .ping(let peerID, let t0):
            var data = Data()
            data.append(peerID.data)
            data.append(contentsOf: encodeUInt64(t0))
            return data
        case .pong(let peerID, let t0, let t1, let t2):
            var data = Data()
            data.append(peerID.data)
            data.append(contentsOf: encodeUInt64(t0))
            data.append(contentsOf: encodeUInt64(t1))
            data.append(contentsOf: encodeUInt64(t2))
            return data
        case .commandBroadcast(let command), .commandUnicast(let command):
            return encodeCommand(command)
        case .heartbeat, .disconnect:
            return Data()
        }
    }

    internal static func encodeCommand(_ command: Command) -> Data {
        let typeBytes = Data(command.type.utf8)
        var data = Data()
        data.append(contentsOf: encodeUInt16(UInt16(typeBytes.count)))
        data.append(typeBytes)
        data.append(command.payload)
        return data
    }

    internal static func decodeCommand(_ payload: Data) throws -> Command {
        guard payload.count >= 2 else {
            throw MessageCodecError.invalidPayload
        }
        let typeLength = Int(decodeUInt16(payload, offset: 0))
        guard payload.count >= 2 + typeLength else {
            throw MessageCodecError.invalidPayload
        }

        let typeData = payload.subdata(in: 2..<(2 + typeLength))
        guard let type = String(data: typeData, encoding: .utf8) else {
            throw MessageCodecError.invalidPayload
        }
        let commandPayload = payload.subdata(in: (2 + typeLength)..<payload.count)
        return Command(type: type, payload: commandPayload)
    }

    private static func decodeHello(_ payload: Data) throws -> Message {
        guard payload.count == 18 else {
            throw MessageCodecError.invalidPayload
        }
        let peerID = try PeerID(data: payload.subdata(in: 0..<16))
        let protocolVersion = decodeUInt16(payload, offset: 16)
        return .hello(peerID: peerID, protocolVersion: protocolVersion)
    }

    private static func decodePing(_ payload: Data) throws -> Message {
        guard payload.count == 24 else {
            throw MessageCodecError.invalidPayload
        }
        let peerID = try PeerID(data: payload.subdata(in: 0..<16))
        let t0 = decodeUInt64(payload, offset: 16)
        return .ping(peerID: peerID, t0: t0)
    }

    private static func decodePong(_ payload: Data) throws -> Message {
        guard payload.count == 40 else {
            throw MessageCodecError.invalidPayload
        }
        let peerID = try PeerID(data: payload.subdata(in: 0..<16))
        let t0 = decodeUInt64(payload, offset: 16)
        let t1 = decodeUInt64(payload, offset: 24)
        let t2 = decodeUInt64(payload, offset: 32)
        return .pong(peerID: peerID, t0: t0, t1: t1, t2: t2)
    }

    private static func encodeUInt16(_ value: UInt16) -> [UInt8] {
        [
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private static func decodeUInt16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func encodeUInt64(_ value: UInt64) -> [UInt8] {
        [
            UInt8((value >> 56) & 0xFF),
            UInt8((value >> 48) & 0xFF),
            UInt8((value >> 40) & 0xFF),
            UInt8((value >> 32) & 0xFF),
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }

    private static func decodeUInt64(_ data: Data, offset: Int) -> UInt64 {
        UInt64(data[offset]) << 56
        | UInt64(data[offset + 1]) << 48
        | UInt64(data[offset + 2]) << 40
        | UInt64(data[offset + 3]) << 32
        | UInt64(data[offset + 4]) << 24
        | UInt64(data[offset + 5]) << 16
        | UInt64(data[offset + 6]) << 8
        | UInt64(data[offset + 7])
    }
}
