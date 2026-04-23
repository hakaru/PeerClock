import Testing
import Foundation
@testable import PeerClock

@Suite("Auto topology — end-to-end transition")
struct AutoTransitionIntegrationTests {

    @Test("peer count threshold triggers full swap to StarTransport end-to-end")
    func meshToStarSwapEndToEnd() async throws {
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(3)))
        try await pc.start()
        defer { Task { await pc.stop() } }

        // Initial state: mesh transport
        #expect(pc.testHook_currentTransportKind.contains("WiFiTransport"))
        let restartsBefore = pc.testHook_restartCount
        #expect(restartsBefore >= 1)  // initial start

        // Inject peer observations — simulates AutoRuntime's internal observer
        // seeing ≥3 peers. This exercises the natural pipe:
        //  injected count → AutoRuntime.onPeerCount → settle window →
        //  announceTransitionReady → transitionEvents yield →
        //  PeerClock.handleTransition → AutoRuntime.performTransition →
        //  PeerClock.restartServices against StarTransport.
        pc.testHook_injectAutoPeers(count: 3)

        // AutoRuntime's default settleWindow is 3s; StarRuntime.start()
        // (HostElection) takes ~2s. Wait up to 8s with margin.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if pc.testHook_currentTransportKind.contains("StarTransport") { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(pc.testHook_currentTransportKind.contains("StarTransport"))
        #expect(pc.testHook_restartCount > restartsBefore)
    }
}
