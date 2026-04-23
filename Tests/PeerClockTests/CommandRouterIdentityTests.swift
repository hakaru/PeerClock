import Foundation
import Testing
@testable import PeerClock

@Suite("CommandRouter — Identity & Dedup")
struct CommandRouterIdentityTests {

    @Test("send() attaches commandID and monotonic logicalVersion")
    func sendAttachesIdentity() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let senderRouter = CommandRouter(transport: senderTransport, localPeerID: senderID)
        _ = senderRouter

        let receiverTask = Task<[Message], Never> {
            var messages: [Message] = []
            for await (_, data) in peerTransport.incomingMessages {
                if let message = try? MessageCodec.decode(data) {
                    messages.append(message)
                    if messages.count == 2 { break }
                }
            }
            return messages
        }

        try await senderRouter.send(Command(type: "a"), to: peerID)
        try await senderRouter.send(Command(type: "b"), to: peerID)
        let messages = await receiverTask.value

        #expect(messages.count == 2)
        guard
            case .commandUnicast(let firstID, let firstVersion, let firstSender, let firstCommand) = messages[0],
            case .commandUnicast(let secondID, let secondVersion, let secondSender, let secondCommand) = messages[1]
        else {
            Issue.record("Expected two commandUnicast messages")
            return
        }

        #expect(firstSender == senderID)
        #expect(secondSender == senderID)
        #expect(firstCommand.type == "a")
        #expect(secondCommand.type == "b")
        #expect(firstID != secondID)
        #expect(firstVersion == 1)
        #expect(secondVersion == 2)
    }

    @Test("duplicate commandID is dropped")
    func duplicateDropped() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let received = Received<(PeerID, Command)>()
        let receiveTask = Task {
            for await item in peerRouter.incomingCommands {
                received.append(item)
            }
        }

        let commandID = UUID()
        let message = Message.commandUnicast(
            commandID: commandID,
            logicalVersion: 1,
            senderID: senderID,
            command: Command(type: "dup")
        )
        let data = MessageCodec.encode(message)

        try await senderTransport.broadcast(data)
        try await senderTransport.broadcast(data)
        try await Task.sleep(for: .milliseconds(150))
        receiveTask.cancel()

        #expect(received.all.count == 1)
        #expect(received.all.first?.1.type == "dup")
    }

    @Test("stale logicalVersion is dropped")
    func staleVersionDropped() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let received = Received<(PeerID, Command)>()
        let receiveTask = Task {
            for await item in peerRouter.incomingCommands {
                received.append(item)
            }
        }

        let messages: [Message] = [
            .commandUnicast(commandID: UUID(), logicalVersion: 3, senderID: senderID, command: Command(type: "v3")),
            .commandUnicast(commandID: UUID(), logicalVersion: 5, senderID: senderID, command: Command(type: "v5")),
            .commandUnicast(commandID: UUID(), logicalVersion: 4, senderID: senderID, command: Command(type: "v4"))
        ]
        for message in messages {
            try await senderTransport.broadcast(MessageCodec.encode(message))
        }

        try await Task.sleep(for: .milliseconds(150))
        receiveTask.cancel()

        let types = received.all.map(\.1.type)
        #expect(types == ["v3", "v5"])
    }

    @Test("same commandID from different senders does not collide")
    func independentSenders() async throws {
        let network = MockNetwork()
        let senderA = PeerID(UUID())
        let senderB = PeerID(UUID())
        let peerID = PeerID(UUID())
        let transportA = await network.createTransport(for: senderA)
        let transportB = await network.createTransport(for: senderB)
        let peerTransport = await network.createTransport(for: peerID)
        try await transportA.start()
        try await transportB.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let received = Received<(PeerID, Command)>()
        let receiveTask = Task {
            for await item in peerRouter.incomingCommands {
                received.append(item)
                if received.all.count >= 2 { break }
            }
        }

        let sharedID = UUID()
        let messageA = Message.commandUnicast(
            commandID: sharedID,
            logicalVersion: 1,
            senderID: senderA,
            command: Command(type: "from-a")
        )
        let messageB = Message.commandUnicast(
            commandID: sharedID,
            logicalVersion: 1,
            senderID: senderB,
            command: Command(type: "from-b")
        )
        try await transportA.broadcast(MessageCodec.encode(messageA))
        try await transportB.broadcast(MessageCodec.encode(messageB))

        _ = await receiveTask.value
        let types = Set(received.all.map(\.1.type))
        #expect(types == ["from-a", "from-b"])
    }

    @Test("LRU eviction allows oldest commandID to be delivered again")
    func lruEviction() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID, maxSeenPerSender: 3)
        let received = Received<(PeerID, Command)>()
        let receiveTask = Task {
            for await item in peerRouter.incomingCommands {
                received.append(item)
            }
        }

        let ids = [UUID(), UUID(), UUID(), UUID()]
        for (index, id) in ids.enumerated() {
            let message = Message.commandUnicast(
                commandID: id,
                logicalVersion: UInt64(index + 1),
                senderID: senderID,
                command: Command(type: "cmd-\(index)")
            )
            try await senderTransport.broadcast(MessageCodec.encode(message))
        }

        let replay = Message.commandUnicast(
            commandID: ids[0],
            logicalVersion: 5,
            senderID: senderID,
            command: Command(type: "cmd-replayed")
        )
        try await senderTransport.broadcast(MessageCodec.encode(replay))
        try await Task.sleep(for: .milliseconds(200))
        receiveTask.cancel()

        let types = received.all.map(\.1.type)
        #expect(types.contains("cmd-replayed"))
    }

    @Test("forgetPeer clears dedup state")
    func forgetPeerResetsState() async throws {
        let network = MockNetwork()
        let senderID = PeerID(UUID())
        let peerID = PeerID(UUID())
        let senderTransport = await network.createTransport(for: senderID)
        let peerTransport = await network.createTransport(for: peerID)
        try await senderTransport.start()
        try await peerTransport.start()

        let peerRouter = CommandRouter(transport: peerTransport, localPeerID: peerID)
        let received = Received<(PeerID, Command)>()
        let receiveTask = Task {
            for await item in peerRouter.incomingCommands {
                received.append(item)
            }
        }

        let commandID = UUID()
        let message = Message.commandUnicast(
            commandID: commandID,
            logicalVersion: 1,
            senderID: senderID,
            command: Command(type: "same-id")
        )
        let data = MessageCodec.encode(message)

        try await senderTransport.broadcast(data)
        try await Task.sleep(for: .milliseconds(50))
        peerRouter.forgetPeer(senderID)
        try await senderTransport.broadcast(data)
        try await Task.sleep(for: .milliseconds(150))
        receiveTask.cancel()

        #expect(received.all.count == 2)
    }
}

private final class Received<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.withLock { items.append(item) }
    }

    var all: [T] {
        lock.withLock { items }
    }
}
