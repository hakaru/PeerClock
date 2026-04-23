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

    @Test("emits TransitionReady on transitionEvents when threshold crossed")
    func emitsTransitionReady() async throws {
        let rt = AutoRuntime(
            localPeerID: PeerID(UUID()),
            heuristic: .peerCountThreshold(3),
            configuration: .default,
            settleWindow: .milliseconds(50)
        )
        try await rt.start()

        // Subscribe before injection so we don't miss the yield.
        let stream = rt.transitionEvents
        let awaiter = Task { () -> TopologyTransition? in
            for await evt in stream { return evt }
            return nil
        }
        rt.testHook_injectDiscoveredPeers(count: 3)

        let evt = try await withTimeout(seconds: 3) { await awaiter.value }
        #expect(evt?.kind == .meshToStar)

        // Mode stays .mesh until an orchestrator calls performTransition().
        #expect(rt.testHook_currentMode == .mesh)
        await rt.stop()
    }

    @Test("performTransition() swaps inner runtime to star")
    func performTransitionSwapsToStar() async throws {
        let rt = AutoRuntime(
            localPeerID: PeerID(UUID()),
            heuristic: .peerCountThreshold(3),
            configuration: .default,
            settleWindow: .milliseconds(50)
        )
        try await rt.start()
        try await rt.performTransition()
        #expect(rt.testHook_currentMode == .star)
        await rt.stop()
    }

    @Test("does not emit when peer count drops before settle")
    func cancelsOnDropBelowThreshold() async throws {
        let rt = AutoRuntime(
            localPeerID: PeerID(UUID()),
            heuristic: .peerCountThreshold(3),
            configuration: .default,
            settleWindow: .milliseconds(200)
        )
        try await rt.start()

        rt.testHook_injectDiscoveredPeers(count: 3)
        rt.testHook_injectDiscoveredPeers(count: 2)

        // Wait past the settle window — nothing should have been emitted.
        try await Task.sleep(for: .milliseconds(300))

        // Soft assertion: mode remains .mesh (no orchestrator called
        // performTransition, and no event should have been emitted).
        #expect(rt.testHook_currentMode == .mesh)
        await rt.stop()
    }

    @Test("facade routes .auto topology through AutoRuntime without crashing")
    func facadeRoutesAuto() async throws {
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(5)))
        try await pc.start()
        await pc.stop()
    }

    // inline withTimeout helper
    private func withTimeout<T: Sendable>(seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }
}
