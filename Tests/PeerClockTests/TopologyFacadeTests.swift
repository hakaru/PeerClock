import Testing
import Foundation
@testable import PeerClock

@Suite("Topology facade")
struct TopologyFacadeTests {

    @Test("default topology is .mesh")
    func defaultTopologyIsMesh() {
        let pc = PeerClock()
        #expect(pc.topology == .mesh)
    }

    @Test("explicit .star(role: .clientOnly)")
    func explicitStarTopology() {
        let pc = PeerClock(topology: .star(role: .clientOnly))
        guard case .star(let role) = pc.topology, role == .clientOnly else {
            Issue.record("expected .star(role: .clientOnly)"); return
        }
    }

    @Test("version is 0.4.0")
    func versionIs040() {
        #expect(PeerClock.version == "0.4.0")
    }
}
