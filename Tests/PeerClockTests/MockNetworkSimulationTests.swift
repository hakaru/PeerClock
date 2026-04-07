import Foundation
import Testing
@testable import PeerClock

@Suite("MockNetwork Simulation")
struct MockNetworkSimulationTests {

    @Test("simulateDisconnect removes peer from others peer lists")
    func simulateDisconnectRemovesPeerFromOthersPeerLists() async throws {
        let network = MockNetwork()
        let peerA = PeerID(UUID())
        let peerB = PeerID(UUID())
        let transportA = await network.createTransport(for: peerA)
        let transportB = await network.createTransport(for: peerB)

        try await transportA.start()
        try await transportB.start()
        try await waitForPeer(peerA, in: transportB.peers, present: true)

        await network.simulateDisconnect(peer: peerA)

        try await waitForPeer(peerA, in: transportB.peers, present: false)
    }

    @Test("simulateDisconnect then simulateReconnect restores routing")
    func simulateDisconnectThenSimulateReconnectRestoresRouting() async throws {
        let network = MockNetwork()
        let peerA = PeerID(UUID())
        let peerB = PeerID(UUID())
        let transportA = await network.createTransport(for: peerA)
        let transportB = await network.createTransport(for: peerB)

        try await transportA.start()
        try await transportB.start()
        try await waitForPeer(peerA, in: transportB.peers, present: true)

        await network.simulateDisconnect(peer: peerA)
        try await waitForPeer(peerA, in: transportB.peers, present: false)

        await network.simulateReconnect(peer: peerA)

        try await waitForPeer(peerA, in: transportB.peers, present: true)
    }

    @Test("Messages to disconnected peer are dropped")
    func messagesToDisconnectedPeerAreDropped() async throws {
        let network = MockNetwork()
        let peerA = PeerID(UUID())
        let peerB = PeerID(UUID())
        let transportA = await network.createTransport(for: peerA)
        let transportB = await network.createTransport(for: peerB)

        try await transportA.start()
        try await transportB.start()

        await network.simulateDisconnect(peer: peerB)
        try await transportA.send(Data([0x01, 0x02]), to: peerB)
        try await Task.sleep(for: .milliseconds(50))

        let receiveTask = Task<[Data], Never> {
            var received: [Data] = []
            for await (_, data) in transportB.incomingMessages {
                received.append(data)
            }
            return received
        }

        try await Task.sleep(for: .milliseconds(100))
        receiveTask.cancel()
        let received = await receiveTask.value

        #expect(received.isEmpty)
    }

    private func waitForPeer(
        _ target: PeerID,
        in stream: AsyncStream<Set<PeerID>>,
        present: Bool
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await peers in stream {
                    if peers.contains(target) == present {
                        return
                    }
                }
                Issue.record("Peer stream finished before expected state was observed")
            }

            group.addTask {
                try await Task.sleep(for: .seconds(1))
                Issue.record("Timed out waiting for peer presence \(present)")
            }

            try await group.next()
            group.cancelAll()
        }
    }
}
