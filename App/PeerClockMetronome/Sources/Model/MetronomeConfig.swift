import Foundation

enum TimeSignature: String, Sendable, CaseIterable, Codable {
    case fourFour = "4/4"
    case threeFour = "3/4"
    case fourEight = "4/8"
    case threeEight = "3/8"
    case sixEight = "6/8"
    case nineEight = "9/8"
    case twelveEight = "12/8"

    var beatsPerBar: Int {
        switch self {
        case .fourFour, .fourEight, .twelveEight: 4
        case .threeFour, .threeEight, .nineEight: 3
        case .sixEight: 2
        }
    }

    var subdivisionsPerBeat: Int {
        switch self {
        case .fourFour, .threeFour: 1
        case .fourEight, .threeEight: 1
        case .sixEight, .nineEight, .twelveEight: 3
        }
    }

    var conductorBeats: Int { beatsPerBar }

    var displayName: String { rawValue }
}

struct MetronomeConfig: Sendable, Equatable, Codable {
    var bpm: Int = 120
    var timeSignature: TimeSignature = .fourFour

    var beatsPerBar: Int { timeSignature.beatsPerBar }
    var subdivisionsPerBeat: Int { timeSignature.subdivisionsPerBeat }
    var totalSubsPerBar: Int { beatsPerBar * subdivisionsPerBeat }

    var beatIntervalSeconds: Double {
        60.0 / Double(bpm)
    }

    var subIntervalSeconds: Double {
        beatIntervalSeconds / Double(subdivisionsPerBeat)
    }
}

enum TickType: Sendable {
    case downbeat
    case beat
    case subdivision
}
