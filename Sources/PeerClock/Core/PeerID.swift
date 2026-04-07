import Foundation

/// A unique identifier for a peer device on the network.
public struct PeerID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {

    /// The underlying UUID value.
    public let rawValue: UUID

    public init(_ uuid: UUID) {
        self.rawValue = uuid
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }

    /// First 8 characters of the UUID string in lowercase.
    public var description: String {
        String(rawValue.uuidString.lowercased().prefix(8))
    }

    internal var data: Data {
        let uuid = rawValue.uuid
        return withUnsafeBytes(of: uuid) { Data($0) }
    }

    internal init(data: Data) throws {
        guard data.count == 16 else {
            throw MessageCodecError.invalidPayload
        }
        let bytes = Array(data)
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        self.init(uuid)
    }

    private var bytes: [UInt8] {
        let uuid = rawValue.uuid
        return [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ]
    }
}
