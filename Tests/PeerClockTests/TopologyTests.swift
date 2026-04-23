import Testing
import Foundation
@testable import PeerClock

@Suite("Topology")
struct TopologyTests {
    @Test("mesh constructs")
    func mesh() {
        let t: Topology = .mesh
        if case .mesh = t {} else { Issue.record("expected .mesh") }
    }

    @Test("star() defaults to role .auto")
    func starDefault() {
        let t: Topology = .star()
        guard case .star(let role) = t, role == .auto else {
            Issue.record("expected .star(role: .auto)"); return
        }
    }

    @Test("star(role: .clientOnly)")
    func starClientOnly() {
        let t: Topology = .star(role: .clientOnly)
        guard case .star(let role) = t, role == .clientOnly else {
            Issue.record("expected .star(role: .clientOnly)"); return
        }
    }

    @Test("auto() defaults to peerCountThreshold(5)")
    func autoDefault() {
        let t: Topology = .auto()
        guard case .auto(let h) = t, h == .peerCountThreshold(5) else {
            Issue.record("expected .auto(.peerCountThreshold(5))"); return
        }
    }
}
