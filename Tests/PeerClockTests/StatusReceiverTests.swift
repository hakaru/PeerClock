import Foundation
import Testing
@testable import PeerClock

@Suite("StatusReceiver")
struct StatusReceiverTests {

    @Test("Ingests first push and emits after debounce")
    func firstPushEmits() async throws {
        let receiver = StatusReceiver(debounce: 0.05)
        let peer = PeerID(rawValue: UUID())

        // Subscribe BEFORE ingest so we don't miss the event.
        let collector = Task { () -> RemotePeerStatus? in
            for await snapshot in receiver.updates {
                return snapshot
            }
            return nil
        }

        let accepted = await receiver.ingestPush(
            from: peer,
            generation: 1,
            entries: [StatusEntry(key: "k", value: Data("v".utf8))]
        )
        #expect(accepted)

        // Wait for debounce to fire.
        try await Task.sleep(nanoseconds: 250_000_000)
        collector.cancel()
        let emitted = await collector.value
        #expect(emitted?.peerID == peer)
        #expect(emitted?.generation == 1)
        #expect(emitted?.entries["k"] == Data("v".utf8))
    }

    @Test("Drops older or equal generation")
    func dropsStale() async {
        let receiver = StatusReceiver(debounce: 0.02)
        let peer = PeerID(rawValue: UUID())
        _ = await receiver.ingestPush(from: peer, generation: 5, entries: [])
        let accepted1 = await receiver.ingestPush(from: peer, generation: 5, entries: [])
        let accepted2 = await receiver.ingestPush(from: peer, generation: 4, entries: [])
        let accepted3 = await receiver.ingestPush(from: peer, generation: 6, entries: [])
        #expect(accepted1 == false)
        #expect(accepted2 == false)
        #expect(accepted3 == true)
    }

    @Test("status(of:) returns last known value")
    func lastKnownValue() async {
        let receiver = StatusReceiver(debounce: 0.02)
        let peer = PeerID(rawValue: UUID())
        _ = await receiver.ingestPush(
            from: peer,
            generation: 1,
            entries: [StatusEntry(key: "k", value: Data("v".utf8))]
        )
        let s = await receiver.status(of: peer)
        #expect(s?.entries["k"] == Data("v".utf8))
    }

    @Test("Debounce collapses rapid updates into single event")
    func debounceCollapses() async throws {
        let receiver = StatusReceiver(debounce: 0.08)
        let peer = PeerID(rawValue: UUID())

        // Collector running in parallel.
        let collector = Task { () -> [RemotePeerStatus] in
            var out: [RemotePeerStatus] = []
            for await snapshot in receiver.updates {
                out.append(snapshot)
            }
            return out
        }

        _ = await receiver.ingestPush(from: peer, generation: 1, entries: [])
        _ = await receiver.ingestPush(from: peer, generation: 2, entries: [])
        _ = await receiver.ingestPush(from: peer, generation: 3, entries: [])

        try await Task.sleep(nanoseconds: 300_000_000)
        await receiver.shutdown()
        let events = await collector.value
        #expect(events.count == 1)
        #expect(events.first?.generation == 3)
    }
}
