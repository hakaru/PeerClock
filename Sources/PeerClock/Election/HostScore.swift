import Foundation

/// Score determining host election priority. Compared as a tuple — higher wins.
/// See spec §4.2 for field definitions and §4.3 for tuple comparison rationale.
public struct HostScore: Comparable, Codable, Equatable, Sendable {
    public let manualPin: Int           // 0 or 1
    public let incumbent: Int           // 0 or 1
    public let powerConnected: Int      // 0 or 1
    public let thermalOK: Int           // 0 or 1
    public let deviceTier: Int          // 0-3 (higher = better device)
    public let stablePeerID: UUID       // tiebreaker (smaller UUID wins, but tuple compares as Comparable)

    public init(
        manualPin: Int = 0,
        incumbent: Int = 0,
        powerConnected: Int = 0,
        thermalOK: Int = 0,
        deviceTier: Int = 0,
        stablePeerID: UUID
    ) {
        self.manualPin = manualPin
        self.incumbent = incumbent
        self.powerConnected = powerConnected
        self.thermalOK = thermalOK
        self.deviceTier = deviceTier
        self.stablePeerID = stablePeerID
    }

    /// Tuple comparison — higher tuple wins. PeerID compared in REVERSE so smaller UUID wins.
    public static func < (lhs: HostScore, rhs: HostScore) -> Bool {
        // Compare integer fields first (ascending — higher = better)
        let lhsTuple = (lhs.manualPin, lhs.incumbent, lhs.powerConnected, lhs.thermalOK, lhs.deviceTier)
        let rhsTuple = (rhs.manualPin, rhs.incumbent, rhs.powerConnected, rhs.thermalOK, rhs.deviceTier)
        if lhsTuple != rhsTuple { return lhsTuple < rhsTuple }
        // Tiebreaker: smaller stablePeerID wins → lhs < rhs means lhs has LARGER UUID (loser)
        return lhs.stablePeerID.uuidString > rhs.stablePeerID.uuidString
    }
}
