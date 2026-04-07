import Foundation

/// One key/value entry on the wire. The value is raw bytes (the encoder of
/// choice — binary plist for Codable values, or arbitrary application bytes —
/// is the caller's responsibility).
public struct StatusEntry: Sendable, Equatable {
    public let key: String
    public let value: Data

    public init(key: String, value: Data) {
        self.key = key
        self.value = value
    }
}
