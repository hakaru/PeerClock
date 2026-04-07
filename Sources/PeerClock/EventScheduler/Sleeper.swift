// Sources/PeerClock/EventScheduler/Sleeper.swift
import Foundation

/// 抽象化された非同期スリープ。EventScheduler のテストでは `MockSleeper` を
/// 注入して仮想時刻で `advance(by:)` し、本番では `RealSleeper` で
/// `Task.sleep` を呼ぶ。
public protocol Sleeper: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

/// 本番実装。`Task.sleep(nanoseconds:)` を呼ぶだけ。
public struct RealSleeper: Sleeper {
    public init() {}
    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

/// テスト実装。
///
/// `sleep(nanoseconds:)` は continuation を waiter キューに enqueue し、
/// 仮想時刻を `advance(by:)` で進めると満期に達した waiter を resume する。
/// `cancelAll()` で全 waiter を CancellationError で起こす。
public actor MockSleeper: Sleeper {
    private var virtualNow: UInt64 = 0
    private struct Waiter {
        let id: UUID
        let deadline: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []

    public init() {}

    public nonisolated func sleep(nanoseconds: UInt64) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Task { await self.enqueue(nanoseconds: nanoseconds, cont: cont) }
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    private func enqueue(nanoseconds: UInt64, cont: CheckedContinuation<Void, Error>) {
        let waiter = Waiter(
            id: UUID(),
            deadline: virtualNow &+ nanoseconds,
            continuation: cont
        )
        waiters.append(waiter)
    }

    /// Advance the virtual clock and resume any waiter whose deadline has passed.
    public func advance(by nanoseconds: UInt64) {
        virtualNow &+= nanoseconds
        let due = waiters
            .filter { $0.deadline <= virtualNow }
            .sorted { $0.deadline < $1.deadline }
        let dueIDs = Set(due.map { $0.id })
        waiters.removeAll { dueIDs.contains($0.id) }
        for w in due {
            w.continuation.resume()
        }
    }

    /// Cancel every pending waiter (used for shutdown).
    public func cancelAll() {
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.continuation.resume(throwing: CancellationError())
        }
    }

    public func pendingCount() -> Int { waiters.count }
}
