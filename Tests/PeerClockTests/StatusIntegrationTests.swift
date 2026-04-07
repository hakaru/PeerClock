import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — Status integration")
struct StatusIntegrationTests {

    @Test("Two peers exchange custom status via facade")
    func customStatusRoundTrip() async throws {
        let network = MockNetwork()
        let config = Configuration(
            statusSendDebounce: 0.05,
            statusReceiveDebounce: 0.05
        )

        let a = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })

        try await a.start()
        try await b.start()

        // 相互発見を待つ
        try await waitForPeers(on: a, count: 1)
        try await waitForPeers(on: b, count: 1)

        // A がカスタムステータスをセット
        try await a.setStatus("recording", forKey: "com.test.state")

        // B 側でそれを観測する
        let observed = try await withTimeout(seconds: 3.0) {
            for await snapshot in b.statusUpdates {
                if snapshot.peerID == a.localPeerID,
                   let data = snapshot.entries["com.test.state"],
                   let decoded = try? StatusValueEncoder.decode(String.self, from: data),
                   decoded == "recording" {
                    return decoded
                }
            }
            return ""
        }
        #expect(observed == "recording")

        await a.stop()
        await b.stop()
    }

    @Test("Disconnected peer's last known status is retained")
    func retainAfterDisconnect() async throws {
        let network = MockNetwork()
        let config = Configuration(
            statusSendDebounce: 0.05,
            statusReceiveDebounce: 0.05
        )
        let a = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(configuration: config, transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })

        try await a.start()
        try await b.start()
        try await waitForPeers(on: b, count: 1)

        try await a.setStatus("v1", forKey: "com.test.k")

        // デバウンス + 配送を待つ
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = await b.status(of: a.localPeerID)
        #expect(before?.entries["com.test.k"] != nil)

        await a.stop()
        // スナップショットは残っているはず
        let after = await b.status(of: a.localPeerID)
        #expect(after?.entries["com.test.k"] != nil)

        await b.stop()
    }

    // MARK: - Helpers

    private func waitForPeers(on clock: PeerClock, count: Int, timeout: TimeInterval = 5.0) async throws {
        try await withTimeout(seconds: timeout) {
            for await list in clock.peers {
                // MockNetwork の peers ストリームは自分自身を除いたセットを配信する。
                if list.count >= count { return }
            }
        }
    }

    @discardableResult
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
