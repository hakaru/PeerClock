import Foundation
import Testing
@testable import PeerClock

@Suite("MockTransport")
struct MockTransportTests {

    @Test("Two peers exchange ping and pong")
    func twoPeerPingPong() async throws {
        let network = MockNetwork()
        let peerA = await network.createTransport(for: PeerID(UUID()))
        let peerB = await network.createTransport(for: PeerID(UUID()))
        try await peerA.start()
        try await peerB.start()

        let message = Message.ping(peerID: peerA.localPeerID, t0: 42)
        let receivedTask = Task<Message, Error> {
            for await (_, data) in peerB.incomingMessages {
                return try MessageCodec.decode(data)
            }
            throw CancellationError()
        }

        try await peerA.send(MessageCodec.encode(message), to: peerB.localPeerID)
        let received = try await receivedTask.value
        #expect(received == message)

        let pongTask = Task<Message, Error> {
            for await (_, data) in peerA.incomingMessages {
                return try MessageCodec.decode(data)
            }
            throw CancellationError()
        }

        try await peerB.send(
            MessageCodec.encode(.pong(peerID: peerB.localPeerID, t0: 42, t1: 100, t2: 120)),
            to: peerA.localPeerID
        )
        let pong = try await pongTask.value
        #expect(pong == .pong(peerID: peerB.localPeerID, t0: 42, t1: 100, t2: 120))
    }

    @Test("Broadcast reaches all peers")
    func broadcastToNPeers() async throws {
        let network = MockNetwork()
        let sender = await network.createTransport(for: PeerID(UUID()))
        let peerB = await network.createTransport(for: PeerID(UUID()))
        let peerC = await network.createTransport(for: PeerID(UUID()))
        try await sender.start()
        try await peerB.start()
        try await peerC.start()

        let payload = MessageCodec.encode(.heartbeat)
        let receiverB = Task<Int, Never> {
            for await _ in peerB.incomingMessages {
                return 1
            }
            return 0
        }
        let receiverC = Task<Int, Never> {
            for await _ in peerC.incomingMessages {
                return 1
            }
            return 0
        }

        try await sender.broadcast(payload)
        let received = await receiverB.value + receiverC.value
        #expect(received == 2)
    }

    @Test("Latency is applied before delivery")
    func latencySimulation() async throws {
        let network = MockNetwork()
        let sender = await network.createTransport(for: PeerID(UUID()), latency: .milliseconds(80))
        let receiver = await network.createTransport(for: PeerID(UUID()))
        try await sender.start()
        try await receiver.start()

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            let receiveTask = Task<Void, Error> {
                for await _ in receiver.incomingMessages {
                    return
                }
                throw CancellationError()
            }
            try await sender.send(MessageCodec.encode(.heartbeat), to: receiver.localPeerID)
            try await receiveTask.value
        }

        #expect(elapsed >= .milliseconds(70))
    }
}
