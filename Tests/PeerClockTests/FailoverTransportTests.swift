// Tests/PeerClockTests/FailoverTransportTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("FailoverTransport")
struct FailoverTransportTests {

    @Test("Empty options throw noOptionsAvailable")
    func emptyOptionsThrow() async throws {
        let failover = FailoverTransport(options: [])
        do {
            try await failover.start()
            Issue.record("Expected throw")
        } catch FailoverTransportError.noOptionsAvailable {
            // ok
        }
    }

    @Test("All options throw → allOptionsFailed with ordered underlying")
    func allOptionsFail() async throws {
        let failover = FailoverTransport(options: [
            .init(label: "A") { ThrowingMockTransport(label: "A") },
            .init(label: "B") { ThrowingMockTransport(label: "B") },
        ])

        do {
            try await failover.start()
            Issue.record("Expected throw")
        } catch FailoverTransportError.allOptionsFailed(let underlying) {
            #expect(underlying.count == 2)
            #expect((underlying[0] as? ThrowingMockTransport.FailureError)?.label == "A")
            #expect((underlying[1] as? ThrowingMockTransport.FailureError)?.label == "B")
        }

        #expect(failover.activeLabel == nil)
    }

    @Test("First throwing option falls back to second successful option")
    func fallbackSucceeds() async throws {
        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())

        let failover = FailoverTransport(options: [
            .init(label: "Bad") { ThrowingMockTransport(label: "Bad") },
            .init(label: "Good") { MockTransport(localPeerID: localID, network: network) },
        ])

        try await failover.start()
        #expect(failover.activeLabel == "Good")

        await failover.stop()
    }

    @Test("Single successful option becomes active")
    func singleSuccess() async throws {
        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())

        let failover = FailoverTransport(options: [
            .init(label: "Only") { MockTransport(localPeerID: localID, network: network) }
        ])

        try await failover.start()
        #expect(failover.activeLabel == "Only")

        await failover.stop()
        #expect(failover.activeLabel == nil)
    }

    @Test("send throws notStarted before start")
    func sendBeforeStartThrows() async throws {
        let failover = FailoverTransport(options: [])
        do {
            try await failover.send(Data(), to: PeerID(rawValue: UUID()))
            Issue.record("Expected throw")
        } catch FailoverTransportError.notStarted {
            // ok
        }
    }

    @Test("Active transport's peers stream is forwarded")
    func peersForwarded() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())

        let failoverA = FailoverTransport(options: [
            .init(label: "A") { MockTransport(localPeerID: a, network: network) }
        ])
        let transportB = MockTransport(localPeerID: b, network: network)

        try await failoverA.start()
        try await transportB.start()

        // failoverA should see B appear via the forwarded stream.
        var it = failoverA.peers.makeAsyncIterator()
        var sawB = false
        for _ in 0..<10 {
            if let next = await it.next(), next.contains(b) {
                sawB = true
                break
            }
        }
        #expect(sawB)

        await failoverA.stop()
        await transportB.stop()
    }

    @Test("broadcast is forwarded to active transport")
    func broadcastForwarded() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())

        let failoverA = FailoverTransport(options: [
            .init(label: "A") { MockTransport(localPeerID: a, network: network) }
        ])
        let transportB = MockTransport(localPeerID: b, network: network)

        try await failoverA.start()
        try await transportB.start()

        // Wait for B to see A.
        var peersIt = transportB.peers.makeAsyncIterator()
        while let next = await peersIt.next() {
            if next.contains(a) { break }
        }

        // Broadcast from failoverA → transportB should receive.
        let payload = Data([0x42, 0x43, 0x44])
        try await failoverA.broadcast(payload)

        var incomingIt = transportB.incomingMessages.makeAsyncIterator()
        let received = await incomingIt.next()
        #expect(received?.1 == payload)

        await failoverA.stop()
        await transportB.stop()
    }

    @Test("Failing option is stopped before moving to next")
    func failedOptionIsStopped() async throws {
        // Capture the ThrowingMockTransport instance by reference.
        final class Box: @unchecked Sendable {
            var transport: ThrowingMockTransport?
        }
        let box = Box()

        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())

        let failover = FailoverTransport(options: [
            .init(label: "Bad") {
                let t = ThrowingMockTransport(label: "Bad")
                box.transport = t
                return t
            },
            .init(label: "Good") { MockTransport(localPeerID: localID, network: network) }
        ])

        try await failover.start()
        #expect(box.transport?.stopWasCalled == true)

        await failover.stop()
    }
}
