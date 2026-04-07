import Testing
import Foundation
@testable import PeerClock

@Suite("CommandRouter")
struct CommandRouterTests {
    @Test("Send command to specific peer")
    func sendToPeer() async throws {
        let network = MockNetwork()
        let peerA = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let peerB = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let transportA = await network.createTransport(for: peerA)
        let transportB = await network.createTransport(for: peerB)
        try await transportA.start()
        try await transportB.start()
        let routerA = CommandRouter(transport: transportA)
        let routerB = CommandRouter(transport: transportB)

        let receiveTask = Task<(PeerID, Command)?, Never> {
            for await (sender, cmd) in routerB.incomingCommands { return (sender, cmd) }
            return nil
        }
        try? await Task.sleep(for: .milliseconds(10))
        let cmd = Command(type: "com.test.ping", payload: Data([0x42]))
        try await routerA.send(cmd, to: peerB)
        try? await Task.sleep(for: .milliseconds(50))
        receiveTask.cancel()
        let received = await receiveTask.value
        #expect(received?.0 == peerA)
        #expect(received?.1.type == "com.test.ping")
        #expect(received?.1.payload == Data([0x42]))
    }

    @Test("Broadcast command to all peers")
    func broadcast() async throws {
        let network = MockNetwork()
        let peerA = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let peerB = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let peerC = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let transportA = await network.createTransport(for: peerA)
        let transportB = await network.createTransport(for: peerB)
        let transportC = await network.createTransport(for: peerC)
        try await transportA.start()
        try await transportB.start()
        try await transportC.start()
        let routerA = CommandRouter(transport: transportA)
        let routerB = CommandRouter(transport: transportB)
        let routerC = CommandRouter(transport: transportC)
        let taskB = Task<Bool, Never> {
            for await (_, cmd) in routerB.incomingCommands {
                if cmd.type == "com.test.broadcast" { return true }
            }
            return false
        }
        let taskC = Task<Bool, Never> {
            for await (_, cmd) in routerC.incomingCommands {
                if cmd.type == "com.test.broadcast" { return true }
            }
            return false
        }
        try? await Task.sleep(for: .milliseconds(10))
        let cmd = Command(type: "com.test.broadcast", payload: Data())
        try await routerA.broadcast(cmd)
        try? await Task.sleep(for: .milliseconds(50))
        taskB.cancel()
        taskC.cancel()
        let receivedB = await taskB.value
        let receivedC = await taskC.value
        #expect(receivedB)
        #expect(receivedC)
    }
}
