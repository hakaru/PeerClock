import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — Coordinator re-election")
struct CoordinatorReelectionTests {

    @Test("Smallest peer ID is coordinator initially")
    func initialElection() async throws {
        let network = MockNetwork()
        let clocks = (0..<3).map { _ in
            PeerClock(transportFactory: { id in
                MockTransport(localPeerID: id, network: network)
            })
        }

        for clock in clocks {
            try await clock.start()
        }

        defer {
            Task {
                for clock in clocks {
                    await clock.stop()
                }
            }
        }

        for clock in clocks {
            try await withTimeout(seconds: 3.0) {
                for await list in clock.peers {
                    if list.count >= 2 {
                        return
                    }
                }
                throw CancellationError()
            }
        }

        try await withTimeout(seconds: 3.0) {
            while true {
                let expected = clocks.map(\.localPeerID).min()!
                if clocks.allSatisfy({ $0.coordinatorID == expected }) {
                    return
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        let expectedCoordinator = clocks.map(\.localPeerID).min()!
        for clock in clocks {
            #expect(clock.coordinatorID == expectedCoordinator)
        }
    }

    @Test("Coordinator leaves; others elect a new coordinator")
    func coordinatorLeaves() async throws {
        let network = MockNetwork()
        let clocks = (0..<3).map { _ in
            PeerClock(transportFactory: { id in
                MockTransport(localPeerID: id, network: network)
            })
        }

        for clock in clocks {
            try await clock.start()
        }

        defer {
            Task {
                for clock in clocks {
                    await clock.stop()
                }
            }
        }

        for clock in clocks {
            try await withTimeout(seconds: 3.0) {
                for await list in clock.peers {
                    if list.count >= 2 {
                        return
                    }
                }
                throw CancellationError()
            }
        }

        let sorted = clocks.sorted { $0.localPeerID < $1.localPeerID }
        let coordinator = sorted[0]
        let remaining = Array(sorted.dropFirst())
        let expectedNewCoordinator = remaining.map(\.localPeerID).min()!

        await network.simulateDisconnect(peer: coordinator.localPeerID)

        for clock in remaining {
            try await withTimeout(seconds: 5.0) {
                while true {
                    if clock.coordinatorID == expectedNewCoordinator {
                        return
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
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
