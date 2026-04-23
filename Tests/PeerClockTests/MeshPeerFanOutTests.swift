import Testing
import Foundation
@testable import PeerClock

@Suite("MeshRuntime peer fan-out")
struct MeshPeerFanOutTests {

    // MARK: - Inline synthetic transport

    /// Yields a single fixed peer set immediately on construction.
    /// Internal to this test file — not intended for production use.
    final class StubTransport: Transport, @unchecked Sendable {
        let peers: AsyncStream<Set<PeerID>>
        let incomingMessages: AsyncStream<(PeerID, Data)>
        private let peersCont: AsyncStream<Set<PeerID>>.Continuation
        private let incomingCont: AsyncStream<(PeerID, Data)>.Continuation

        init(_ initial: Set<PeerID>) {
            var pc: AsyncStream<Set<PeerID>>.Continuation!
            self.peers = AsyncStream { pc = $0 }
            self.peersCont = pc

            var ic: AsyncStream<(PeerID, Data)>.Continuation!
            self.incomingMessages = AsyncStream { ic = $0 }
            self.incomingCont = ic

            // Yield synchronously — AsyncStream buffers until a consumer iterates.
            peersCont.yield(initial)
        }

        func start() async throws {}
        func stop() async {
            peersCont.finish()
            incomingCont.finish()
        }
        func broadcast(_ data: Data) async throws {}
        func broadcastUnreliable(_ data: Data) async throws {}
    }

    // MARK: - Tests

    @Test("two subscribers observe the same peer updates")
    func twoSubscribersSeePeers() async throws {
        let peerA = PeerID(UUID())
        let peerB = PeerID(UUID())
        let stub = StubTransport(Set([peerA, peerB]))
        let rt = MeshRuntime(transport: stub)
        try await rt.start()
        defer { Task { await rt.stop() } }

        let s1 = rt.subscribePeers()
        let s2 = rt.subscribePeers()

        let seen1 = try await withTimeout(seconds: 2) { await firstValue(of: s1) ?? [] }
        let seen2 = try await withTimeout(seconds: 2) { await firstValue(of: s2) ?? [] }

        #expect(Set(seen1.map { $0.id }) == Set([peerA, peerB]))
        #expect(Set(seen2.map { $0.id }) == Set([peerA, peerB]))
    }

    @Test("currentPeerCount returns the real count")
    func currentPeerCountReal() async throws {
        let stub = StubTransport(Set([PeerID(UUID()), PeerID(UUID()), PeerID(UUID())]))
        let rt = MeshRuntime(transport: stub)
        try await rt.start()
        defer { Task { await rt.stop() } }

        // Give the observer task a moment to consume the stub's peer yield.
        try await Task.sleep(for: .milliseconds(50))

        let count = await rt.currentPeerCount
        #expect(count == 3)
    }

    // MARK: - Helpers

    /// Read the first element of an `AsyncStream`. Returns `nil` if the stream
    /// finishes without yielding. Safe to call from a `@Sendable` closure —
    /// the iterator stays local to this function.
    private func firstValue<T: Sendable>(of stream: AsyncStream<T>) async -> T? {
        for await v in stream { return v }
        return nil
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        _ op: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            let r = try await group.next()!
            group.cancelAll()
            return r
        }
    }
}
