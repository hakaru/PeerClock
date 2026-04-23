import Testing
import Foundation
@testable import PeerClock

@Suite("ConnectionEvents")
struct ConnectionEventsTests {

    @Test("injected handshake failure appears on connectionEvents stream")
    func handshakeFailureInjection() async throws {
        let pc = PeerClock()  // mesh default is fine — hook injects regardless

        let expected = ConnectionEvent(
            reason: .handshakeFailed(.invalidUpgrade),
            peer: nil
        )

        // Start consuming on a child task, then inject.
        let consumer = Task<ConnectionEvent?, Never> {
            var it = pc.connectionEvents.makeAsyncIterator()
            return await it.next()
        }

        // Small delay so the consumer is actually iterating before we yield.
        try await Task.sleep(for: .milliseconds(50))
        pc.testHook_injectConnectionEvent(expected)

        let result = try await withThrowingTaskGroup(of: ConnectionEvent?.self) { group in
            group.addTask { await consumer.value }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                consumer.cancel()
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        #expect(result == expected)
    }

    @Test("reason equality covers handshakeFailed variants")
    func reasonEquality() {
        let a = ConnectionEvent.Reason.handshakeFailed(.invalidUpgrade)
        let b = ConnectionEvent.Reason.handshakeFailed(.invalidUpgrade)
        let c = ConnectionEvent.Reason.handshakeFailed(.badAcceptHash)
        #expect(a == b)
        #expect(a != c)
    }
}
