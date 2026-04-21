import Foundation

struct NTPServerResult: Sendable {
    let host: String
    var offset: TimeInterval
    var rtt: TimeInterval
    var stratum: Int
    var sampledAt: Date
}
