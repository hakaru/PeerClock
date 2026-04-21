import Foundation

struct MetronomeConfig: Sendable, Equatable, Codable {
    var bpm: Int = 120
    var subdivision: Subdivision = .none
    var beatsPerBar: Int = 4

    var beatIntervalSeconds: Double {
        60.0 / Double(bpm)
    }

    var subIntervalSeconds: Double {
        beatIntervalSeconds / Double(subdivision.rawValue)
    }
}

enum Subdivision: Int, Sendable, CaseIterable, Codable {
    case none = 1
    case half = 2
    case triplet = 3
    case quarter = 4
}

enum TickType: Sendable {
    case downbeat
    case beat
    case subdivision
}
