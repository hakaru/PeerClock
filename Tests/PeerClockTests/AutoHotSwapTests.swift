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

    /// Regression test for the Codex/Gemini independent-review finding that
    /// `stop()` and an in-flight `handleTransition` were not serialized. Before
    /// the fix, the transition could complete after `stop()` had torn services
    /// down, spawning new services on a stopped `PeerClock` and leaving
    /// `transport` reassigned.
    ///
    /// After the fix, whichever side wins the race, `stop()` returns with the
    /// facade fully torn down: `transport` is nil and `testHook_restartCount`
    /// reflects either a clean baseline or a completed-then-stopped state —
    /// never a post-stop rebuild.
    @Test("stop() is safe during an in-flight mesh→star transition")
    func stopRacesInFlightTransition() async throws {
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(3)))
        try await pc.start()

        async let transitionDone: Void = pc.testHook_forceMeshToStarTransition()
        async let stopDone: Void = pc.stop()
        _ = await (transitionDone, stopDone)

        #expect(pc.testHook_currentTransportKind == "nil")
    }

    /// Second-order regression: stop → start → stop must still be safe.
    /// Verifies that `isStopped` is correctly reset by `start()`.
    @Test("restart-after-stop works — isStopped is reset")
    func restartAfterStop() async throws {
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(5)))
        try await pc.start()
        await pc.stop()

        try await pc.start()
        // If isStopped wasn't reset, the immediate handleTransition path
        // would be blocked. Force a transition and assert it runs.
        let countBefore = pc.testHook_restartCount
        await pc.testHook_forceMeshToStarTransition()
        #expect(pc.testHook_restartCount > countBefore)

        await pc.stop()
        #expect(pc.testHook_currentTransportKind == "nil")
    }
}
