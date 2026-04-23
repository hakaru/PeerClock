import Testing
import Foundation
@testable import PeerClock

/// Byte-identity tests for mesh `MessageCodec` output vs a pinned v0.2.x baseline.
///
/// Fixtures were generated from this worktree. `Sources/PeerClock/Wire/` has had
/// zero commits since v0.2.1 at the time of fixture creation (verified via
/// `git log v0.2.1..HEAD -- Sources/PeerClock/Wire/`), so current encoder output
/// equals v0.2.1 output.
///
/// Regenerate fixtures: `REGENERATE_WIRE_FIXTURES=1 swift test --filter WireCompat`.
///
/// Any change that breaks these tests signifies a mesh-wire-format change —
/// PeerClockMetronome v1.0 compatibility is broken. See `docs/spec/v1-wire-compat.md`.
@Suite("Mesh wire-compat golden fixtures")
struct WireCompatGoldenTests {

    private static let peerA = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private static let peerB = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    private static let commandID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/wire-v2", isDirectory: true)
    }

    private static var shouldRegenerate: Bool {
        ProcessInfo.processInfo.environment["REGENERATE_WIRE_FIXTURES"] == "1"
    }

    private func assertGolden(_ bytes: Data, name: String) throws {
        let path = Self.fixtureDir.appendingPathComponent("\(name).bin")
        if Self.shouldRegenerate {
            try FileManager.default.createDirectory(at: Self.fixtureDir, withIntermediateDirectories: true)
            try bytes.write(to: path)
            Issue.record("REGENERATED \(name).bin — remove REGENERATE_WIRE_FIXTURES=1 to run verification")
            return
        }
        let expected = try Data(contentsOf: path)
        #expect(bytes == expected, "wire drift in \(name)")
    }

    @Test("hello encoding is byte-identical to v0.2.1")
    func helloGolden() throws {
        let m: Message = .hello(peerID: Self.peerA, protocolVersion: 2)
        try assertGolden(MessageCodec.encode(m), name: "hello")
    }

    @Test("ping encoding is byte-identical to v0.2.1")
    func pingGolden() throws {
        let m: Message = .ping(peerID: Self.peerA, t0: 12345)
        try assertGolden(MessageCodec.encode(m), name: "ping")
    }

    @Test("pong encoding is byte-identical to v0.2.1")
    func pongGolden() throws {
        let m: Message = .pong(peerID: Self.peerA, t0: 12345, t1: 23456, t2: 34567)
        try assertGolden(MessageCodec.encode(m), name: "pong")
    }

    @Test("commandBroadcast encoding is byte-identical to v0.2.1")
    func commandBroadcastGolden() throws {
        let m: Message = .commandBroadcast(
            commandID: Self.commandID,
            logicalVersion: 42,
            senderID: Self.peerA,
            command: Command(type: "metronome/start", payload: Data([0xAA, 0xBB]))
        )
        try assertGolden(MessageCodec.encode(m), name: "commandBroadcast")
    }

    @Test("commandUnicast encoding is byte-identical to v0.2.1")
    func commandUnicastGolden() throws {
        let m: Message = .commandUnicast(
            commandID: Self.commandID,
            logicalVersion: 42,
            senderID: Self.peerA,
            command: Command(type: "metronome/start", payload: Data([0xAA, 0xBB]))
        )
        try assertGolden(MessageCodec.encode(m), name: "commandUnicast")
    }

    @Test("heartbeat encoding is byte-identical to v0.2.1")
    func heartbeatGolden() throws {
        let m: Message = .heartbeat
        try assertGolden(MessageCodec.encode(m), name: "heartbeat")
    }

    @Test("statusPush encoding is byte-identical to v0.2.1")
    func statusPushGolden() throws {
        let entries = [
            StatusEntry(key: "role", value: Data("coordinator".utf8)),
            StatusEntry(key: "bpm", value: Data([0x00, 0x78])), // 120
        ]
        let m: Message = .statusPush(senderID: Self.peerA, generation: 7, entries: entries)
        try assertGolden(MessageCodec.encode(m), name: "statusPush")
    }

    @Test("statusRequest encoding is byte-identical to v0.2.1")
    func statusRequestGolden() throws {
        let m: Message = .statusRequest(senderID: Self.peerA, correlation: 0xBEEF)
        try assertGolden(MessageCodec.encode(m), name: "statusRequest")
    }

    @Test("statusResponse encoding is byte-identical to v0.2.1")
    func statusResponseGolden() throws {
        let entries = [
            StatusEntry(key: "role", value: Data("coordinator".utf8)),
        ]
        let m: Message = .statusResponse(
            senderID: Self.peerA,
            correlation: 0xBEEF,
            generation: 7,
            entries: entries
        )
        try assertGolden(MessageCodec.encode(m), name: "statusResponse")
    }

    @Test("disconnect encoding is byte-identical to v0.2.1")
    func disconnectGolden() throws {
        let m: Message = .disconnect
        try assertGolden(MessageCodec.encode(m), name: "disconnect")
    }
}
