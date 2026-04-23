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

    @Test("version is 0.4.1")
    func versionIs041() {
        #expect(PeerClock.version == "0.4.1")
    }

    @Test("star topology starts and stops without throwing")
    func starTopologyStartStop() async throws {
        let pc = PeerClock(topology: .star(role: .auto))
        try await pc.start()
        await pc.stop()
    }

    @Test("star clientOnly topology starts and stops without throwing")
    func starClientOnlyStartStop() async throws {
        let pc = PeerClock(topology: .star(role: .clientOnly))
        try await pc.start()
        await pc.stop()
    }
}
