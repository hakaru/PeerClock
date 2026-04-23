import Testing
import Foundation
@testable import PeerClock

@Suite("AutoRuntime transitions")
struct AutoTopologyTransitionTests {

    @Test("starts in mesh mode")
    func startsAsMesh() async throws {
        let rt = AutoRuntime(
            localPeerID: PeerID(UUID()),
            heuristic: .peerCountThreshold(3),
            configuration: .default,
            settleWindow: .milliseconds(50)
        )
        try await rt.start()
        #expect(rt.testHook_currentMode == .mesh)
        await rt.stop()
    }

    @Test("transitions to star when peer count exceeds threshold after settle window")
    func transitionsAboveThreshold() async throws {
        let rt = AutoRuntime(
            localPeerID: PeerID(UUID()),
            heuristic: .peerCountThreshold(3),
            configuration: .default,
            settleWindow: .milliseconds(50)
        )
        try await rt.start()

        rt.testHook_injectDiscoveredPeers(count: 3)
        await rt.testHook_waitForSettleWindow()

        #expect(rt.testHook_currentMode == .star)
        await rt.stop()
    }

    @Test("does not transition when peer count drops before settle")
    func cancelsOnDropBelowThreshold() async throws {
        let rt = AutoRuntime(
            localPeerID: PeerID(UUID()),
            heuristic: .peerCountThreshold(3),
            configuration: .default,
            settleWindow: .milliseconds(200)
        )
        try await rt.start()

        rt.testHook_injectDiscoveredPeers(count: 3) // triggers settle
        rt.testHook_injectDiscoveredPeers(count: 2) // cancels settle
        try await Task.sleep(for: .milliseconds(300))

        #expect(rt.testHook_currentMode == .mesh)
        await rt.stop()
    }

    @Test("facade routes .auto topology through AutoRuntime without crashing")
    func facadeRoutesAuto() async throws {
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(5)))
        try await pc.start()
        await pc.stop()
    }
}
