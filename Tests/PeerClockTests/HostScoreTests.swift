import Testing
import Foundation
@testable import PeerClock

@Suite("HostScore")
struct HostScoreTests {
    @Test func powerBeatsBattery() {
        let id = UUID()
        let powered = HostScore(powerConnected: 1, deviceTier: 1, stablePeerID: id)
        let battery = HostScore(powerConnected: 0, deviceTier: 1, stablePeerID: id)
        #expect(powered > battery)
    }

    @Test func deviceTierBreaksTie() {
        let highTier = HostScore(deviceTier: 3, stablePeerID: UUID())
        let lowTier = HostScore(deviceTier: 1, stablePeerID: UUID())
        #expect(highTier > lowTier)
    }

    @Test func smallerUUIDWinsAtTie() {
        let smallUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let largeUUID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let a = HostScore(deviceTier: 1, stablePeerID: smallUUID)
        let b = HostScore(deviceTier: 1, stablePeerID: largeUUID)
        #expect(a > b)  // smaller UUID wins
    }

    @Test func roundTripCodable() throws {
        let original = HostScore(
            manualPin: 1, incumbent: 1, powerConnected: 1, thermalOK: 1, deviceTier: 2,
            stablePeerID: UUID()
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostScore.self, from: data)
        #expect(decoded == original)
    }
}
