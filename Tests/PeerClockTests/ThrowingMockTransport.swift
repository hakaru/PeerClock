// Tests/PeerClockTests/ThrowingMockTransport.swift
import Foundation
@testable import PeerClock

/// A Transport whose `start()` always throws. Used by FailoverTransportTests
/// to simulate a failing option.
final class ThrowingMockTransport: Transport, @unchecked Sendable {

    struct FailureError: Error, Equatable {
        let label: String
    }

    let label: String
    let peers: AsyncStream<Set<PeerID>>
    let incomingMessages: AsyncStream<(PeerID, Data)>
    private(set) var stopWasCalled = false

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingContinuation: AsyncStream<(PeerID, Data)>.Continuation
    private let lock = NSLock()

    init(label: String) {
        self.label = label

        var peersCont: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont

        var incomingCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingCont = $0 }
        self.incomingContinuation = incomingCont
    }

    func start() async throws {
        throw FailureError(label: label)
    }

    func stop() async {
        lock.withLock { stopWasCalled = true }
        peersContinuation.finish()
        incomingContinuation.finish()
    }

    func broadcast(_ data: Data) async throws {
        throw FailureError(label: label)
    }
}
