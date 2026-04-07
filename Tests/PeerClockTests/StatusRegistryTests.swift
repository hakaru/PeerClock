import Foundation
import Testing
@testable import PeerClock

@Suite("StatusRegistry")
struct StatusRegistryTests {

    // Helper: captures broadcast messages for assertions.
    actor Capture {
        var messages: [Message] = []
        func append(_ m: Message) { messages.append(m) }
        func all() -> [Message] { messages }
    }

    @Test("Multiple setStatus calls within debounce window flush once")
    func debounceCollapsesUpdates() async throws {
        let capture = Capture()
        let registry = StatusRegistry(
            localPeerID: PeerID(rawValue: UUID()),
            debounce: 0.05
        ) { msg in
            await capture.append(msg)
        }

        await registry.setStatus(Data("a".utf8), forKey: "k1")
        await registry.setStatus(Data("b".utf8), forKey: "k2")
        await registry.setStatus(Data("c".utf8), forKey: "k1") // overwrites

        try await Task.sleep(nanoseconds: 200_000_000) // > debounce window
        let msgs = await capture.all()
        #expect(msgs.count == 1)
        guard case .statusPush(_, let gen, let entries) = msgs[0] else {
            Issue.record("Expected statusPush")
            return
        }
        #expect(gen == 1)
        let keys = Set(entries.map { $0.key })
        #expect(keys == ["k1", "k2"])
        let k1 = entries.first { $0.key == "k1" }?.value
        #expect(k1 == Data("c".utf8))
    }

    @Test("Generation increments on each flush, not each set")
    func generationPerSnapshot() async throws {
        let capture = Capture()
        let registry = StatusRegistry(
            localPeerID: PeerID(rawValue: UUID()),
            debounce: 0.03
        ) { msg in
            await capture.append(msg)
        }

        await registry.setStatus(Data("1".utf8), forKey: "k")
        try await Task.sleep(nanoseconds: 100_000_000)
        await registry.setStatus(Data("2".utf8), forKey: "k")
        try await Task.sleep(nanoseconds: 100_000_000)

        let msgs = await capture.all()
        #expect(msgs.count == 2)
        guard
            case .statusPush(_, let g1, _) = msgs[0],
            case .statusPush(_, let g2, _) = msgs[1]
        else {
            Issue.record("Expected two statusPush")
            return
        }
        #expect(g1 == 1)
        #expect(g2 == 2)
    }

    @Test("flushNow emits immediately")
    func flushNowImmediate() async throws {
        let capture = Capture()
        let registry = StatusRegistry(
            localPeerID: PeerID(rawValue: UUID()),
            debounce: 10.0
        ) { msg in
            await capture.append(msg)
        }

        await registry.setStatus(Data("x".utf8), forKey: "k")
        await registry.flushNow()

        let msgs = await capture.all()
        #expect(msgs.count == 1)
    }

    @Test("Codable setStatus encodes via binary plist")
    func codableEncode() async throws {
        let capture = Capture()
        let registry = StatusRegistry(
            localPeerID: PeerID(rawValue: UUID()),
            debounce: 0.03
        ) { msg in
            await capture.append(msg)
        }

        struct Sample: Codable, Equatable, Sendable {
            let n: Int
            let s: String
        }

        try await registry.setStatus(Sample(n: 42, s: "hi"), forKey: "sample")
        try await Task.sleep(nanoseconds: 100_000_000)

        let msgs = await capture.all()
        guard case .statusPush(_, _, let entries) = msgs.first else {
            Issue.record("Expected statusPush")
            return
        }
        let valueData = entries.first { $0.key == "sample" }?.value
        #expect(valueData != nil)
        let decoded = try StatusValueEncoder.decode(Sample.self, from: valueData!)
        #expect(decoded == Sample(n: 42, s: "hi"))
    }

    @Test("Flush with no dirty state is a no-op")
    func idleFlushNoOp() async throws {
        let capture = Capture()
        let registry = StatusRegistry(
            localPeerID: PeerID(rawValue: UUID()),
            debounce: 0.02
        ) { msg in
            await capture.append(msg)
        }

        await registry.flushNow()
        #expect(await capture.all().isEmpty)
    }
}
