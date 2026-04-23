import Testing
import Foundation
@testable import PeerClock

@Suite("StarRuntime")
struct StarRuntimeTests {

    @Test("starts and stops without throwing (auto role)")
    func startStopAuto() async throws {
        let rt = StarRuntime(
            localPeerID: PeerID(UUID()),
            role: .auto,
            configuration: .default
        )
        try await rt.start()
        await rt.stop()
    }

    @Test("starts and stops without throwing (clientOnly role)")
    func startStopClientOnly() async throws {
        let rt = StarRuntime(
            localPeerID: PeerID(UUID()),
            role: .clientOnly,
            configuration: .default
        )
        try await rt.start()
        await rt.stop()
    }

    @Test("transport is a StarTransport")
    func transportIsStarTransport() {
        let rt = StarRuntime(
            localPeerID: PeerID(UUID()),
            role: .auto,
            configuration: .default
        )
        #expect(rt.transport is StarTransport)
    }
}
