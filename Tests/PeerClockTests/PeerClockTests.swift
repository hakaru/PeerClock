import Testing
import Foundation
@testable import PeerClock

@Suite("PeerClock Facade")
struct PeerClockTests {

    @Test("PeerClock version is defined")
    func version() {
        #expect(!PeerClock.version.isEmpty)
    }

    @Test("PeerClock can be initialized with default configuration")
    func initDefault() {
        let clock = PeerClock()
        #expect(clock != nil)
    }

    @Test("Two peers discover each other and sync via MockTransport")
    func twoPeerSync() async throws {
        let network = MockNetwork()
        let config = Configuration(
            syncInterval: 1.0,
            syncMeasurements: 4,
            syncMeasurementInterval: 0.01
        )

        let clockA = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })
        let clockB = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })

        try await clockA.start()
        try await clockB.start()

        // Simulate peer discovery
        network.simulateJoin(clockA.localPeerID)
        network.simulateJoin(clockB.localPeerID)

        // Wait for sync
        try await Task.sleep(for: .milliseconds(500))

        await clockA.stop()
        await clockB.stop()
    }

    @Test("Command sent from A is received by B")
    func commandRouting() async throws {
        let network = MockNetwork()
        let config = Configuration(syncMeasurements: 2, syncMeasurementInterval: 0.01)

        let clockA = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })
        let clockB = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })

        try await clockA.start()
        try await clockB.start()

        network.simulateJoin(clockA.localPeerID)
        network.simulateJoin(clockB.localPeerID)

        try? await Task.sleep(for: .milliseconds(50))

        let receiveTask = Task<Command?, Never> {
            for await (_, cmd) in clockB.commands {
                return cmd
            }
            return nil
        }

        try? await Task.sleep(for: .milliseconds(10))

        try await clockA.send(
            Command(type: "com.test.action", payload: Data([0x01])),
            to: clockB.localPeerID
        )

        try? await Task.sleep(for: .milliseconds(100))
        receiveTask.cancel()

        let received = await receiveTask.value
        #expect(received?.type == "com.test.action")

        await clockA.stop()
        await clockB.stop()
    }
}
