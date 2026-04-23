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

    // MARK: - StarTransport plumbing

    @Test("StarTransport.reportConnectionEvent yields on connectionEvents stream")
    func starTransportReportYieldsEvent() async throws {
        let transport = StarTransport(localPeerID: PeerID(UUID()))

        // Start iterating, then publish a sequence of events. Confirms
        // both that the continuation is wired and that multiple events
        // flow through in order.
        let consumer = Task<[ConnectionEvent], Never> {
            var events: [ConnectionEvent] = []
            for await event in transport.connectionEvents {
                events.append(event)
                if events.count >= 3 { break }
            }
            return events
        }

        // Small delay so consumer actually starts iterating.
        try await Task.sleep(for: .milliseconds(50))

        let e1 = ConnectionEvent(reason: .handshakeFailed(.invalidUpgrade))
        let e2 = ConnectionEvent(reason: .handshakeFailed(.oversizedFrame))
        let e3 = ConnectionEvent(reason: .timeout)
        transport.reportConnectionEvent(e1)
        transport.reportConnectionEvent(e2)
        transport.reportConnectionEvent(e3)

        let result = try await withThrowingTaskGroup(of: [ConnectionEvent].self) { group in
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

        #expect(result.count == 3)
        #expect(result[0].reason == .handshakeFailed(.invalidUpgrade))
        #expect(result[1].reason == .handshakeFailed(.oversizedFrame))
        #expect(result[2].reason == .timeout)
    }

    // MARK: - MeshRuntime never yields

    @Test("MeshRuntime.connectionEvents yields nothing before stop()")
    func meshRuntimeNeverYieldsEvents() async throws {
        let network = MockNetwork()
        let transport = MockTransport(localPeerID: PeerID(UUID()), network: network)
        let mesh = MeshRuntime(transport: transport)

        let consumer = Task<ConnectionEvent?, Never> {
            var it = mesh.connectionEvents.makeAsyncIterator()
            return await it.next()
        }

        // Give the consumer some time to attempt a read.
        try await Task.sleep(for: .milliseconds(200))

        // Stop the runtime — this should finish the stream, so the consumer
        // returns nil rather than a real event.
        await mesh.stop()

        let result = await consumer.value
        #expect(result == nil)
    }
}
