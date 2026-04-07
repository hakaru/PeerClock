import Foundation

public enum MessageCodecError: Error, Sendable, Equatable {
    case truncatedData
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case invalidLength(Int)
    case invalidPayload
}

public enum MessageCodec {

    private static let version: UInt8 = 0x02
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
            let (cid, ver, sender, cmd) = try decodeIdentifiedCommand(payload)
            return .commandBroadcast(commandID: cid, logicalVersion: ver, senderID: sender, command: cmd)
        case 0x11:
            let (cid, ver, sender, cmd) = try decodeIdentifiedCommand(payload)
            return .commandUnicast(commandID: cid, logicalVersion: ver, senderID: sender, command: cmd)
        case 0x20:
            guard payload.isEmpty else { throw MessageCodecError.invalidPayload }
            return .heartbeat
        case 0x30:
            return try decodeStatusPush(payload)
        case 0x31:
            return try decodeStatusRequest(payload)
        case 0x32:
            return try decodeStatusResponse(payload)
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
        case .commandBroadcast(let cid, let ver, let sender, let command),
             .commandUnicast(let cid, let ver, let sender, let command):
            var data = Data()
            data.append(contentsOf: encodeUUID(cid))
            data.append(contentsOf: encodeUInt64(ver))
            data.append(sender.data)
            data.append(encodeCommand(command))
            return data
        case .statusPush(let senderID, let generation, let entries):
            var data = Data()
            data.append(senderID.data)
            data.append(contentsOf: encodeUInt64(generation))
            data.append(contentsOf: encodeUInt16(UInt16(entries.count)))
            for entry in entries {
                data.append(encodeStatusEntry(entry))
            }
            return data
        case .statusRequest(let senderID, let correlation):
            var data = Data()
            data.append(senderID.data)
            data.append(contentsOf: encodeUInt16(correlation))
            return data
        case .statusResponse(let senderID, let correlation, let generation, let entries):
            var data = Data()
            data.append(senderID.data)
            data.append(contentsOf: encodeUInt16(correlation))
            data.append(contentsOf: encodeUInt64(generation))
            data.append(contentsOf: encodeUInt16(UInt16(entries.count)))
            for entry in entries {
                data.append(encodeStatusEntry(entry))
            }
            return data
        case .heartbeat, .disconnect:
            return Data()
        }
    }

    internal static func encodeStatusEntry(_ entry: StatusEntry) -> Data {
        let keyBytes = Data(entry.key.utf8)
        var data = Data()
        data.append(contentsOf: encodeUInt16(UInt16(keyBytes.count)))
        data.append(keyBytes)
        data.append(contentsOf: encodeUInt16(UInt16(entry.value.count)))
        data.append(entry.value)
        return data
    }

    internal static func decodeStatusEntries(_ payload: Data, offset: inout Int, count: Int) throws -> [StatusEntry] {
        var entries: [StatusEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 2 <= payload.count else { throw MessageCodecError.invalidPayload }
            let keyLen = Int(decodeUInt16(payload, offset: offset))
            offset += 2
            guard offset + keyLen <= payload.count else { throw MessageCodecError.invalidPayload }
            let keyData = payload.subdata(in: offset..<(offset + keyLen))
            guard let key = String(data: keyData, encoding: .utf8) else { throw MessageCodecError.invalidPayload }
            offset += keyLen
            guard offset + 2 <= payload.count else { throw MessageCodecError.invalidPayload }
            let valueLen = Int(decodeUInt16(payload, offset: offset))
            offset += 2
            guard offset + valueLen <= payload.count else { throw MessageCodecError.invalidPayload }
            let value = payload.subdata(in: offset..<(offset + valueLen))
            offset += valueLen
            entries.append(StatusEntry(key: key, value: value))
        }
        return entries
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

    private static func decodeStatusPush(_ payload: Data) throws -> Message {
        // sender(16) + generation(8) + entries_count(2) + entries
        guard payload.count >= 26 else { throw MessageCodecError.invalidPayload }
        let senderID = try PeerID(data: payload.subdata(in: 0..<16))
        let generation = decodeUInt64(payload, offset: 16)
        let count = Int(decodeUInt16(payload, offset: 24))
        var offset = 26
        let entries = try decodeStatusEntries(payload, offset: &offset, count: count)
        guard offset == payload.count else { throw MessageCodecError.invalidPayload }
        return .statusPush(senderID: senderID, generation: generation, entries: entries)
    }

    private static func decodeStatusRequest(_ payload: Data) throws -> Message {
        guard payload.count == 18 else { throw MessageCodecError.invalidPayload }
        let senderID = try PeerID(data: payload.subdata(in: 0..<16))
        let correlation = decodeUInt16(payload, offset: 16)
        return .statusRequest(senderID: senderID, correlation: correlation)
    }

    private static func decodeStatusResponse(_ payload: Data) throws -> Message {
        // sender(16) + correlation(2) + generation(8) + entries_count(2) + entries
        guard payload.count >= 28 else { throw MessageCodecError.invalidPayload }
        let senderID = try PeerID(data: payload.subdata(in: 0..<16))
        let correlation = decodeUInt16(payload, offset: 16)
        let generation = decodeUInt64(payload, offset: 18)
        let count = Int(decodeUInt16(payload, offset: 26))
        var offset = 28
        let entries = try decodeStatusEntries(payload, offset: &offset, count: count)
        guard offset == payload.count else { throw MessageCodecError.invalidPayload }
        return .statusResponse(senderID: senderID, correlation: correlation, generation: generation, entries: entries)
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

    // MARK: - v2 Helpers

    private static func encodeUUID(_ uuid: UUID) -> [UInt8] {
        let bytes = uuid.uuid
        return [
            bytes.0, bytes.1, bytes.2, bytes.3,
            bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11,
            bytes.12, bytes.13, bytes.14, bytes.15
        ]
    }

    private static func decodeUUID(_ data: Data, offset: Int) throws -> UUID {
        guard data.count >= offset + 16 else {
            throw MessageCodecError.truncatedData
        }
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 16)))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Decode [16B UUID][8B version][16B PeerID][Command] payload.
    private static func decodeIdentifiedCommand(
        _ payload: Data
    ) throws -> (UUID, UInt64, PeerID, Command) {
        let commandID = try decodeUUID(payload, offset: 0)
        let logicalVersion = decodeUInt64(payload, offset: 16)
        guard payload.count >= 40 else {
            throw MessageCodecError.truncatedData
        }
        let senderID = try PeerID(data: payload.subdata(in: 24..<40))
        let command = try decodeCommand(payload.subdata(in: 40..<payload.count))
        return (commandID, logicalVersion, senderID, command)
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
