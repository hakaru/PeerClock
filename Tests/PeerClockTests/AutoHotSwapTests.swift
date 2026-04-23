import Testing
import Foundation
@testable import PeerClock

@Suite("Auto topology — facade hot-swap")
struct AutoHotSwapTests {

    @Test("forceMeshToStar triggers restartServices against star transport")
    func forceTransitionRestartsServices() async throws {
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(5)))
        try await pc.start()
        defer { Task { await pc.stop() } }

        let countBefore = pc.testHook_restartCount
        #expect(countBefore >= 1)  // initial start counts

        await pc.testHook_forceMeshToStarTransition()

        let countAfter = pc.testHook_restartCount
        #expect(countAfter > countBefore)
    }
}
