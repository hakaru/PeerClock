import Testing
import Foundation
@testable import PeerClock

@Suite("Transport protocol")
struct TransportProtocolTests {

    @Test("broadcast reaches the other peer (smoke test)")
    func broadcastReachesPeer() async throws {
        let network = MockNetwork()
        let a = PeerID(UUID())
        let b = PeerID(UUID())
        let transportA = await network.createTransport(for: a)
        let transportB = await network.createTransport(for: b)
        try await transportA.start()
        try await transportB.start()

        let payload = Data([0xAA, 0xBB])

        // Begin iterating B's stream BEFORE broadcasting to avoid a race where
        // the message is delivered before the iterator starts consuming.
        let receiveTask = Task<(PeerID, Data)?, Never> {
            for await item in transportB.incomingMessages {
                return item
            }
            return nil
        }

        try await transportA.broadcast(payload)

        let received = try await withTimeout(seconds: 2) {
            await receiveTask.value
        }
        #expect(received?.1 == payload)

        await transportA.stop()
        await transportB.stop()
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
