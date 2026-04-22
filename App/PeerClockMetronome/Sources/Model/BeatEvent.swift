import Foundation

/// A single beat broadcast from a conductor (local or remote) to all peers.
/// Carries enough metadata to recover from packet loss/reordering and time-align playback.
struct BeatEvent: Sendable, Codable {
    let sessionID: UUID
    let sequence: UInt32
    let beatIndexInBar: UInt8
    let tickType: TickType
    let applyAtNs: UInt64
}

extension TickType: Codable {
    private enum CodedValue: String, Codable {
        case downbeat, beat, subdivision
    }
    public init(from decoder: Decoder) throws {
        let v = try decoder.singleValueContainer().decode(CodedValue.self)
        switch v {
        case .downbeat: self = .downbeat
        case .beat: self = .beat
        case .subdivision: self = .subdivision
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .downbeat: try c.encode(CodedValue.downbeat)
        case .beat: try c.encode(CodedValue.beat)
        case .subdivision: try c.encode(CodedValue.subdivision)
        }
    }
}
