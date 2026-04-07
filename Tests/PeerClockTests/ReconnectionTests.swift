import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — Reconnection")
struct ReconnectionTests {

    @Test("Peer disconnect then reconnect: full status resync via flushNow")
    func fullResyncOnReconnect() async throws {
        let network = MockNetwork()
        let a = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })

        try await a.start()
        try await b.start()

        defer {
            Task {
                await a.stop()
                await b.stop()
            }
        }

        try await waitForPeers(on: a, count: 1)
        try await waitForPeers(on: b, count: 1)

        try await a.setStatus("v1", forKey: "com.test.k")
        let before = try await withTimeout(seconds: 3.0) {
            while true {
                if let snapshot = await b.status(of: a.localPeerID),
                   snapshot.entries["com.test.k"] != nil {
                    return snapshot
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        #expect(before.entries["com.test.k"] != nil)

        await network.simulateDisconnect(peer: a.localPeerID)
        try await Task.sleep(nanoseconds: 500_000_000)

        await network.simulateReconnect(peer: a.localPeerID)

        let received = try await withTimeout(seconds: 3.0) {
            while true {
                if let snapshot = await b.status(of: a.localPeerID),
                   snapshot.entries["com.test.k"] != nil {
                    return true
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        #expect(received)
    }

    @Test("Brief disconnect heals without permanent peer loss")
    func briefDisconnectHeals() async throws {
        let network = MockNetwork()
        let a = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })

        try await a.start()
        try await b.start()

        defer {
            Task {
                await a.stop()
                await b.stop()
            }
        }

        try await waitForPeers(on: a, count: 1)
        try await waitForPeers(on: b, count: 1)

        await network.simulateDisconnect(peer: a.localPeerID)
        try await Task.sleep(nanoseconds: 200_000_000)
        await network.simulateReconnect(peer: a.localPeerID)

        try await withTimeout(seconds: 3.0) {
            for await list in b.peers {
                if list.contains(where: { $0.id == a.localPeerID }) {
                    return
                }
            }
            throw CancellationError()
        }
    }

    private func waitForPeers(on clock: PeerClock, count: Int, timeout: TimeInterval = 3.0) async throws {
        try await withTimeout(seconds: timeout) {
            for await list in clock.peers {
                if list.count >= count {
                    return
                }
            }
            throw CancellationError()
        }
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
