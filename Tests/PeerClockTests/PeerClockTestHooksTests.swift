import Testing
import Foundation
@testable import PeerClock

#if DEBUG
@Suite("PeerClockTestHooks")
struct PeerClockTestHooksTests {
    @Test func partitionBlocksSpecifiedPeers() async {
        let hooks = PeerClockTestHooks.shared
        await hooks.clear()
        let blockedID = UUID()
        await hooks.inject(.partition(peerIDs: [blockedID]))
        #expect(await hooks.isPeerPartitioned(blockedID))
        #expect(await hooks.isPeerPartitioned(UUID()) == false)
        await hooks.clear()
    }

    @Test func killHostFlag() async {
        let hooks = PeerClockTestHooks.shared
        await hooks.clear()
        #expect(await hooks.shouldKillHost() == false)
        await hooks.inject(.killHost)
        #expect(await hooks.shouldKillHost())
        await hooks.clear()
    }

    @Test func clearRemovesAllFaults() async {
        let hooks = PeerClockTestHooks.shared
        await hooks.inject(.killHost)
        await hooks.inject(.partition(peerIDs: [UUID()]))
        await hooks.clear()
        #expect(await hooks.faults.isEmpty)
    }
}
#endif
