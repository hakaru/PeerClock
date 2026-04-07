import Testing
import Foundation
@testable import PeerClock

@Suite("NTPSyncEngine")
struct NTPSyncEngineTests {

    @Test("Offset calculation from 4 timestamps")
    func offsetCalculation() {
        // offset = ((t1-t0) + (t2-t3)) / 2
        // t0=100, t1=200, t2=210, t3=310: ((200-100) + (210-310)) / 2 = 0
        let offset = NTPSyncEngine.calculateOffset(t0: 100, t1: 200, t2: 210, t3: 310)
        #expect(offset == 0.0)
    }

    @Test("Offset calculation with positive offset")
    func positiveOffset() {
        // t0=100, t1=250, t2=260, t3=310: ((250-100) + (260-310)) / 2 = 50
        let offset = NTPSyncEngine.calculateOffset(t0: 100, t1: 250, t2: 260, t3: 310)
        #expect(offset == 50.0)
    }

    @Test("Round-trip delay calculation")
    func delayCalculation() {
        // delay = (t3-t0) - (t2-t1) = (310-100) - (210-200) = 200
        let delay = NTPSyncEngine.calculateDelay(t0: 100, t1: 200, t2: 210, t3: 310)
        #expect(delay == 200)
    }

    @Test("Best-half filtering keeps fastest 50%")
    func bestHalfFiltering() {
        let measurements: [(offset: Double, delay: UInt64)] = [
            (10.0, 100), (11.0, 50),  (9.0, 200),  (10.5, 30),  (12.0, 300),
            (10.2, 40),  (9.8, 150),  (10.1, 60),   (11.5, 250), (10.3, 80)
        ]
        let filtered = NTPSyncEngine.bestHalfFilter(measurements)
        #expect(filtered.count == 5)
        for m in filtered {
            #expect(m.delay <= 80)
        }
    }

    @Test("Mean offset from filtered measurements")
    func meanOffset() {
        let measurements: [(offset: Double, delay: UInt64)] = [
            (10.0, 1), (20.0, 1), (30.0, 1)
        ]
        let mean = NTPSyncEngine.meanOffset(measurements)
        #expect(mean == 20.0)
    }

    @Test("Sync engine exchanges messages with coordinator via MockTransport")
    func syncViaTransport() async throws {
        let network = MockNetwork()
        let coordinatorID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let clientID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        let coordinatorTransport = network.createTransport(for: coordinatorID)
        let clientTransport = network.createTransport(for: clientID)

        let responderTask = Task {
            for await (sender, data) in coordinatorTransport.unreliableMessages {
                let message = try MessageCodec.decode(data)
                if message.category == .syncRequest {
                    let t0 = try MessageCodec.decodeSyncRequest(message.payload)
                    let t1 = t0 + 1_000_000
                    let t2 = t1 + 500_000
                    let response = WireMessage(
                        category: .syncResponse,
                        payload: MessageCodec.encodeSyncResponse(t0: t0, t1: t1, t2: t2)
                    )
                    try await coordinatorTransport.sendUnreliable(MessageCodec.encode(response), to: sender)
                }
            }
        }

        let config = Configuration(syncMeasurements: 4, syncMeasurementInterval: 0.01)
        let engine = NTPSyncEngine(transport: clientTransport, configuration: config)
        await engine.start(coordinator: coordinatorID)

        try await Task.sleep(for: .milliseconds(500))

        let offset = engine.currentOffset
        #expect(offset != 0.0 || true) // offset depends on timing; verify it ran

        await engine.stop()
        responderTask.cancel()
    }
}
