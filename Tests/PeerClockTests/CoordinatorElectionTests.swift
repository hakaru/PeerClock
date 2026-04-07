import Testing
import Foundation
@testable import PeerClock

@Suite("CoordinatorElection")
struct CoordinatorElectionTests {

    let peerA = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let peerB = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let peerC = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    @Test("Single peer is coordinator")
    func singlePeer() {
        let election = CoordinatorElection(localPeerID: peerA)
        election.updatePeers([peerA])
        #expect(election.coordinator == peerA)
        #expect(election.isCoordinator == true)
    }

    @Test("Smallest PeerID becomes coordinator")
    func smallestWins() {
        let election = CoordinatorElection(localPeerID: peerC)
        election.updatePeers([peerA, peerB, peerC])
        #expect(election.coordinator == peerA)
        #expect(election.isCoordinator == false)
    }

    @Test("Coordinator changes when smaller peer joins")
    func newSmallerPeer() {
        let election = CoordinatorElection(localPeerID: peerB)
        election.updatePeers([peerB, peerC])
        #expect(election.coordinator == peerB)
        #expect(election.isCoordinator == true)
        election.updatePeers([peerA, peerB, peerC])
        #expect(election.coordinator == peerA)
        #expect(election.isCoordinator == false)
    }

    @Test("Coordinator changes when current coordinator leaves")
    func coordinatorLeaves() {
        let election = CoordinatorElection(localPeerID: peerB)
        election.updatePeers([peerA, peerB, peerC])
        #expect(election.coordinator == peerA)
        election.updatePeers([peerB, peerC])
        #expect(election.coordinator == peerB)
        #expect(election.isCoordinator == true)
    }

    @Test("No peers means no coordinator")
    func noPeers() {
        let election = CoordinatorElection(localPeerID: peerA)
        #expect(election.coordinator == nil)
    }

    @Test("Coordinator changes are emitted")
    func coordinatorChanges() async {
        let election = CoordinatorElection(localPeerID: peerB)
        let collector = ChangesCollector()
        let task = Task {
            for await coordinator in election.coordinatorUpdates {
                await collector.append(coordinator)
                if await collector.count >= 2 { break }
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        election.updatePeers([peerB, peerC])
        try? await Task.sleep(for: .milliseconds(10))
        election.updatePeers([peerA, peerB, peerC])
        await task.value
        let changes = await collector.changes
        #expect(changes == [peerB, peerA])
    }
}

// MARK: - Helpers

private actor ChangesCollector {
    var changes: [PeerID?] = []
    var count: Int { changes.count }
    func append(_ peerID: PeerID?) { changes.append(peerID) }
}
