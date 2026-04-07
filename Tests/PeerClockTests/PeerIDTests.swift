import Foundation
import Testing
@testable import PeerClock

@Suite("PeerID")
struct PeerIDTests {

    @Test("Comparable ordering uses raw UUID bytes")
    func comparableOrdering() {
        let smallest = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let largest = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!)
        #expect(smallest < largest)
        #expect(!(largest < smallest))
    }

    @Test("Equality and hashing are stable")
    func equality() {
        let uuid = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let a = PeerID(rawValue: uuid)
        let b = PeerID(rawValue: uuid)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
    }

    @Test("Codable round-trips")
    func codableRoundTrip() throws {
        let peerID = PeerID(rawValue: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
        let data = try JSONEncoder().encode(peerID)
        let decoded = try JSONDecoder().decode(PeerID.self, from: data)
        #expect(decoded == peerID)
    }
}
