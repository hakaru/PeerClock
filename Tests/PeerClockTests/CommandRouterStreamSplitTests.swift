import Foundation
import Testing
@testable import PeerClock

@Suite("CommandRouter — Stream split")
struct CommandRouterStreamSplitTests {

    @Test("PING routes to syncRequests only")
    func pingToRequests() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let requestSeen = StreamFlag()
        let responseSeen = StreamFlag()

        let requestTask = Task {
            for await _ in peerRouter.syncRequests {
                requestSeen.set(true)
                break
            }
        }
        let responseTask = Task {
            for await _ in peerRouter.syncResponses {
                responseSeen.set(true)
                break
            }
        }

        try await senderTransport.broadcast(MessageCodec.encode(.ping(peerID: senderID, t0: 123)))
        try await Task.sleep(for: .milliseconds(100))
        requestTask.cancel()
        responseTask.cancel()

        #expect(requestSeen.value == true)
        #expect(responseSeen.value == false)
    }

    @Test("PONG routes to syncResponses only")
    func pongToResponses() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let requestSeen = StreamFlag()
        let responseSeen = StreamFlag()

        let requestTask = Task {
            for await _ in peerRouter.syncRequests {
                requestSeen.set(true)
                break
            }
        }
        let responseTask = Task {
            for await _ in peerRouter.syncResponses {
                responseSeen.set(true)
                break
            }
        }

        try await senderTransport.broadcast(MessageCodec.encode(.pong(peerID: senderID, t0: 1, t1: 2, t2: 3)))
        try await Task.sleep(for: .milliseconds(100))
        requestTask.cancel()
        responseTask.cancel()

        #expect(requestSeen.value == false)
        #expect(responseSeen.value == true)
    }

    @Test("non-sync messages do not leak into split streams")
    func nonSyncMessagesStayOut() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let requestSeen = StreamFlag()
        let responseSeen = StreamFlag()

        let requestTask = Task {
            for await _ in peerRouter.syncRequests {
                requestSeen.set(true)
            }
        }
        let responseTask = Task {
            for await _ in peerRouter.syncResponses {
                responseSeen.set(true)
            }
        }

        let command = Message.commandUnicast(
            commandID: UUID(),
            logicalVersion: 1,
            senderID: senderID,
            command: Command(type: "cmd")
        )
        try await senderTransport.broadcast(MessageCodec.encode(command))
        try await senderTransport.broadcast(MessageCodec.encode(.heartbeat))
        try await Task.sleep(for: .milliseconds(100))
        requestTask.cancel()
        responseTask.cancel()

        #expect(requestSeen.value == false)
        #expect(responseSeen.value == false)
    }
}

private final class StreamFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.withLock { stored }
    }

    func set(_ newValue: Bool) {
        lock.withLock { stored = newValue }
    }
}
