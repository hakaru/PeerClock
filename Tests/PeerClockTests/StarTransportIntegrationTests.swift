import Testing
import Foundation
import Network
@testable import PeerClock

@Suite("StarTransport integration")
struct StarTransportIntegrationTests {

    // Thread-safe collector for use across async task boundaries.
    private actor MessageCollector {
        private(set) var received: Data?
        func store(_ data: Data) { received = data }
    }

    /// Spin up a host, connect a client, verify peers stream + round-trip.
    @Test func hostClientRoundTrip() async throws {
        let hostTransport = StarTransport(localPeerID: PeerID(UUID()))
        let clientTransport = StarTransport(localPeerID: PeerID(UUID()))

        try await hostTransport.promoteToHost()

        // Give NWListener a moment to bind to a port.
        try await Task.sleep(for: .milliseconds(500))

        guard let host = hostTransport.hostForTest else {
            Issue.record("Host not initialized")
            return
        }
        guard let listener = host.listenerForTest, let port = listener.port else {
            Issue.record("Listener has no bound port")
            return
        }

        // Start collecting incoming messages on the host BEFORE the client connects
        // to avoid the race where the message arrives before we begin iterating.
        let collector = MessageCollector()
        let receiveTask = Task {
            for await (_, data) in hostTransport.incomingMessages {
                await collector.store(data)
                return
            }
        }

        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
        await clientTransport.demoteToClient(connectingTo: endpoint, hostPeerID: PeerID(UUID()))

        // Allow time for WebSocket handshake to complete.
        try await Task.sleep(for: .milliseconds(1000))

        // Client → Host: send a test payload.
        let payload = Data("ping-test".utf8)
        try await clientTransport.send(payload, to: PeerID(UUID()))

        // Wait for the message to arrive at the host (with timeout).
        try await Task.sleep(for: .milliseconds(1000))
        receiveTask.cancel()

        let received = await collector.received
        #expect(received == payload)

        await hostTransport.stop()
        await clientTransport.stop()
    }

    /// Verify that a transport in undecided role throws StarTransportError on send.
    @Test func undecidedRoleThrowsOnSend() async {
        let transport = StarTransport(localPeerID: PeerID(UUID()))
        await #expect(throws: StarTransportError.self) {
            try await transport.send(Data("test".utf8), to: PeerID(UUID()))
        }
    }
}
