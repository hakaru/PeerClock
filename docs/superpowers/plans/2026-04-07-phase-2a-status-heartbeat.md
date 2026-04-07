# Phase 2a: Status Sharing + Heartbeat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock に「ステータス共有（push+pull, generation, 二重 debounce）」と「時間ベース Heartbeat（connected/degraded/disconnected）」を追加する。

**Architecture:** 2つの actor（`StatusRegistry` = 送信側、`StatusReceiver` = 受信側）+ 1つの actor（`HeartbeatMonitor`）を新設。`PeerClock` facade がこれらを配線し、既存の Transport 上に STATUS_PUSH / STATUS_REQUEST / STATUS_RESPONSE / HEARTBEAT メッセージを流す。Transport protocol に `broadcastUnreliable` を追加するが、WiFiTransport は当面 TCP への alias（Phase 3 で UDP を追加予定）。

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, Foundation, Network.framework (既存)。

**Spec reference:** `docs/superpowers/specs/2026-04-07-peerclock-v2-design.md` (Phase 2a 節および Actor 境界図)。

---

## File Structure

**Create:**
- `Sources/PeerClock/Status/StatusRegistry.swift` — ローカルステータス保持 + 送信側 debounce + generation 発番
- `Sources/PeerClock/Status/StatusReceiver.swift` — リモートステータスストア + 受信側 debounce + AsyncStream
- `Sources/PeerClock/Status/StatusKeys.swift` — `pc.*` 予約キー定数 + ヘルパ
- `Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift` — 定期送信 + 時間ベース状態遷移
- `Tests/PeerClockTests/StatusRegistryTests.swift`
- `Tests/PeerClockTests/StatusReceiverTests.swift`
- `Tests/PeerClockTests/HeartbeatMonitorTests.swift`
- `Tests/PeerClockTests/StatusIntegrationTests.swift` — facade 経由の end-to-end
- `Tests/PeerClockTests/WireStatusTests.swift` — 新 Message ケースのラウンドトリップ

**Modify:**
- `Sources/PeerClock/Configuration.swift` — 新フィールド追加、`disconnectThreshold` 削除
- `Sources/PeerClock/Wire/Message.swift` — `statusPush` / `statusRequest` / `statusResponse` 追加
- `Sources/PeerClock/Wire/MessageCodec.swift` — 新 Message のエンコード/デコード
- `Sources/PeerClock/Transport/Transport.swift` — `broadcastUnreliable` 追加
- `Sources/PeerClock/Transport/MockTransport.swift` — `broadcastUnreliable` 実装（記録機能付き）
- `Sources/PeerClock/Transport/WiFiTransport.swift` — `broadcastUnreliable` を TCP alias として実装
- `Sources/PeerClock/PeerClock.swift` — 新 actor の配線、`setStatus` / `status(of:)` / `statusUpdates` 公開
- `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift` — ステータス表示と接続状態 UI

---

## Task 1: Configuration schema

**Files:**
- Modify: `Sources/PeerClock/Configuration.swift`

- [ ] **Step 1: Configuration を書き換える**

```swift
import Foundation

/// Runtime configuration for a PeerClock instance.
public struct Configuration: Sendable {

    // MARK: - Heartbeat

    /// Interval in seconds between heartbeat packets.
    public let heartbeatInterval: TimeInterval

    /// After this many seconds with no heartbeat, a peer is marked `.degraded`.
    public let degradedAfter: TimeInterval

    /// After this many seconds with no heartbeat, a peer is marked `.disconnected`.
    public let disconnectedAfter: TimeInterval

    // MARK: - Status debounce

    /// Send-side debounce window. `setStatus` calls within this window are
    /// flushed into a single STATUS_PUSH.
    public let statusSendDebounce: TimeInterval

    /// Receive-side debounce window. `statusUpdates` events for the same peer
    /// within this window are collapsed to one.
    public let statusReceiveDebounce: TimeInterval

    // MARK: - Clock sync

    /// Interval in seconds between sync rounds.
    public let syncInterval: TimeInterval

    /// Number of timing measurements per sync round.
    public let syncMeasurements: Int

    /// Interval in seconds between individual measurements within a sync round.
    public let syncMeasurementInterval: TimeInterval

    // MARK: - Transport

    /// Bonjour service type string.
    public let serviceType: String

    /// Wire protocol version used in HELLO negotiation.
    public let protocolVersion: UInt16

    public init(
        heartbeatInterval: TimeInterval = 1.0,
        degradedAfter: TimeInterval = 2.0,
        disconnectedAfter: TimeInterval = 5.0,
        statusSendDebounce: TimeInterval = 0.1,
        statusReceiveDebounce: TimeInterval = 0.05,
        syncInterval: TimeInterval = 5.0,
        syncMeasurements: Int = 40,
        syncMeasurementInterval: TimeInterval = 0.03,
        serviceType: String = "_peerclock._udp",
        protocolVersion: UInt16 = 1
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.degradedAfter = degradedAfter
        self.disconnectedAfter = disconnectedAfter
        self.statusSendDebounce = statusSendDebounce
        self.statusReceiveDebounce = statusReceiveDebounce
        self.syncInterval = syncInterval
        self.syncMeasurements = syncMeasurements
        self.syncMeasurementInterval = syncMeasurementInterval
        self.serviceType = serviceType
        self.protocolVersion = protocolVersion
    }

    /// Default configuration with sensible values.
    public static let `default` = Configuration()
}
```

- [ ] **Step 2: ビルド確認（既存の `disconnectThreshold` 参照がないことを確認）**

Run: `swift build 2>&1 | tail -20`
Expected: `Build complete!`（警告やエラーなし）

- [ ] **Step 3: 既存テスト実行**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 37 tests in 8 suites passed`

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Configuration.swift
git commit -m "feat(config): add Phase 2a heartbeat and status debounce fields"
```

---

## Task 2: Transport protocol — unreliable channel

**Files:**
- Modify: `Sources/PeerClock/Transport/Transport.swift`
- Modify: `Sources/PeerClock/Transport/MockTransport.swift`
- Modify: `Sources/PeerClock/Transport/WiFiTransport.swift`

- [ ] **Step 1: Transport protocol を拡張**

```swift
import Foundation

public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }

    /// Reliable unicast. 現行の `send` 相当。
    func send(_ data: Data, to peer: PeerID) async throws

    /// Reliable broadcast. 現行の `broadcast` 相当。STATUS_PUSH などに使う。
    func broadcast(_ data: Data) async throws

    /// Unreliable broadcast（HEARTBEAT 用）。
    /// WiFiTransport は当面 TCP broadcast への alias。
    /// Phase 3 で UDP 実装に差し替える。
    func broadcastUnreliable(_ data: Data) async throws
}

public extension Transport {
    /// Default: TCP broadcast にフォールバック。
    func broadcastUnreliable(_ data: Data) async throws {
        try await broadcast(data)
    }
}
```

- [ ] **Step 2: MockTransport に `broadcastUnreliable` の記録を追加**

`Sources/PeerClock/Transport/MockTransport.swift` を開き、`broadcast` 実装の直後に以下を追加:

```swift
    public func broadcastUnreliable(_ data: Data) async throws {
        // テストで HEARTBEAT vs STATUS_PUSH の区別が必要になったら
        // channelLog に記録できるようにするフック。現状は reliable と同一経路。
        try await broadcast(data)
    }
```

- [ ] **Step 3: WiFiTransport は default 実装に委譲（明示的な override は不要）**

何もしない。extension の default が使われる。

- [ ] **Step 4: ビルド & テスト**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 37 tests in 8 suites passed`

- [ ] **Step 5: Commit**

```bash
git add Sources/PeerClock/Transport/Transport.swift Sources/PeerClock/Transport/MockTransport.swift
git commit -m "feat(transport): add broadcastUnreliable for heartbeat channel"
```

---

## Task 3: Wire — Message enum extension

**Files:**
- Modify: `Sources/PeerClock/Wire/Message.swift`
- Create: `Sources/PeerClock/Wire/StatusEntry.swift`

- [ ] **Step 1: StatusEntry 型を作る**

```swift
// Sources/PeerClock/Wire/StatusEntry.swift
import Foundation

/// ワイヤフォーマット上の1エントリ。key と value は生バイト列のまま保持する。
public struct StatusEntry: Sendable, Equatable {
    public let key: String
    public let value: Data

    public init(key: String, value: Data) {
        self.key = key
        self.value = value
    }
}
```

- [ ] **Step 2: Message に新ケースを追加**

`Sources/PeerClock/Wire/Message.swift` を丸ごと以下に置き換え:

```swift
import Foundation

public enum Message: Sendable, Equatable {
    case hello(peerID: PeerID, protocolVersion: UInt16)
    case ping(peerID: PeerID, t0: UInt64)
    case pong(peerID: PeerID, t0: UInt64, t1: UInt64, t2: UInt64)
    case commandBroadcast(Command)
    case commandUnicast(Command)
    case heartbeat
    case statusPush(senderID: PeerID, generation: UInt64, entries: [StatusEntry])
    case statusRequest(senderID: PeerID, correlation: UInt16)
    case statusResponse(senderID: PeerID, correlation: UInt16, generation: UInt64, entries: [StatusEntry])
    case disconnect

    internal var typeByte: UInt8 {
        switch self {
        case .hello: return 0x01
        case .ping: return 0x02
        case .pong: return 0x03
        case .commandBroadcast: return 0x10
        case .commandUnicast: return 0x11
        case .heartbeat: return 0x20
        case .statusPush: return 0x30
        case .statusRequest: return 0x31
        case .statusResponse: return 0x32
        case .disconnect: return 0xFF
        }
    }
}
```

- [ ] **Step 3: ビルド（MessageCodec 側のエラーで落ちるはず — 次タスクで修正）**

Run: `swift build 2>&1 | tail -10`
Expected: `switch must be exhaustive` エラーが MessageCodec.swift で出る

- [ ] **Step 4: Commit（ビルドは次タスクまで壊れたまま）**

```bash
git add Sources/PeerClock/Wire/Message.swift Sources/PeerClock/Wire/StatusEntry.swift
git commit -m "feat(wire): add statusPush/Request/Response message cases"
```

---

## Task 4: Wire — MessageCodec extension

**Files:**
- Modify: `Sources/PeerClock/Wire/MessageCodec.swift`
- Create: `Tests/PeerClockTests/WireStatusTests.swift`

- [ ] **Step 1: MessageCodec に encoder 分岐を追加**

`payload(for:)` 関数の switch に以下のケースを追加（`.heartbeat, .disconnect:` の前に）:

```swift
        case .statusPush(let senderID, let generation, let entries):
            var data = Data()
            data.append(senderID.data)
            data.append(contentsOf: encodeUInt64(generation))
            data.append(contentsOf: encodeUInt16(UInt16(entries.count)))
            for entry in entries {
                data.append(encodeStatusEntry(entry))
            }
            return data
        case .statusRequest(let senderID, let correlation):
            var data = Data()
            data.append(senderID.data)
            data.append(contentsOf: encodeUInt16(correlation))
            return data
        case .statusResponse(let senderID, let correlation, let generation, let entries):
            var data = Data()
            data.append(senderID.data)
            data.append(contentsOf: encodeUInt16(correlation))
            data.append(contentsOf: encodeUInt64(generation))
            data.append(contentsOf: encodeUInt16(UInt16(entries.count)))
            for entry in entries {
                data.append(encodeStatusEntry(entry))
            }
            return data
```

- [ ] **Step 2: decoder 分岐を追加**

`decode(_:)` 関数の switch に以下を追加（`case 0x20:` の後、`case 0xFF:` の前）:

```swift
        case 0x30:
            return try decodeStatusPush(payload)
        case 0x31:
            return try decodeStatusRequest(payload)
        case 0x32:
            return try decodeStatusResponse(payload)
```

- [ ] **Step 3: ヘルパ関数を追加**（MessageCodec enum の末尾 `private static func decodeUInt64` の前に挿入）

```swift
    // MARK: - Status helpers

    internal static func encodeStatusEntry(_ entry: StatusEntry) -> Data {
        let keyBytes = Data(entry.key.utf8)
        var data = Data()
        data.append(contentsOf: encodeUInt16(UInt16(keyBytes.count)))
        data.append(keyBytes)
        data.append(contentsOf: encodeUInt16(UInt16(entry.value.count)))
        data.append(entry.value)
        return data
    }

    internal static func decodeStatusEntries(_ payload: Data, offset: inout Int, count: Int) throws -> [StatusEntry] {
        var entries: [StatusEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 2 <= payload.count else { throw MessageCodecError.invalidPayload }
            let keyLen = Int(decodeUInt16(payload, offset: offset))
            offset += 2
            guard offset + keyLen <= payload.count else { throw MessageCodecError.invalidPayload }
            let keyData = payload.subdata(in: offset..<(offset + keyLen))
            guard let key = String(data: keyData, encoding: .utf8) else { throw MessageCodecError.invalidPayload }
            offset += keyLen
            guard offset + 2 <= payload.count else { throw MessageCodecError.invalidPayload }
            let valueLen = Int(decodeUInt16(payload, offset: offset))
            offset += 2
            guard offset + valueLen <= payload.count else { throw MessageCodecError.invalidPayload }
            let value = payload.subdata(in: offset..<(offset + valueLen))
            offset += valueLen
            entries.append(StatusEntry(key: key, value: value))
        }
        return entries
    }

    private static func decodeStatusPush(_ payload: Data) throws -> Message {
        // sender(16) + generation(8) + entries_count(2) + entries
        guard payload.count >= 26 else { throw MessageCodecError.invalidPayload }
        let senderID = try PeerID(data: payload.subdata(in: 0..<16))
        let generation = decodeUInt64(payload, offset: 16)
        let count = Int(decodeUInt16(payload, offset: 24))
        var offset = 26
        let entries = try decodeStatusEntries(payload, offset: &offset, count: count)
        guard offset == payload.count else { throw MessageCodecError.invalidPayload }
        return .statusPush(senderID: senderID, generation: generation, entries: entries)
    }

    private static func decodeStatusRequest(_ payload: Data) throws -> Message {
        guard payload.count == 18 else { throw MessageCodecError.invalidPayload }
        let senderID = try PeerID(data: payload.subdata(in: 0..<16))
        let correlation = decodeUInt16(payload, offset: 16)
        return .statusRequest(senderID: senderID, correlation: correlation)
    }

    private static func decodeStatusResponse(_ payload: Data) throws -> Message {
        // sender(16) + correlation(2) + generation(8) + entries_count(2) + entries
        guard payload.count >= 28 else { throw MessageCodecError.invalidPayload }
        let senderID = try PeerID(data: payload.subdata(in: 0..<16))
        let correlation = decodeUInt16(payload, offset: 16)
        let generation = decodeUInt64(payload, offset: 18)
        let count = Int(decodeUInt16(payload, offset: 26))
        var offset = 28
        let entries = try decodeStatusEntries(payload, offset: &offset, count: count)
        guard offset == payload.count else { throw MessageCodecError.invalidPayload }
        return .statusResponse(senderID: senderID, correlation: correlation, generation: generation, entries: entries)
    }
```

- [ ] **Step 4: WireStatusTests を作る**

```swift
// Tests/PeerClockTests/WireStatusTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("Wire — Status messages")
struct WireStatusTests {

    @Test("statusPush round-trip with multiple entries")
    func statusPushRoundTrip() throws {
        let sender = PeerID()
        let entries = [
            StatusEntry(key: "pc.device.name", value: Data("iPhone".utf8)),
            StatusEntry(key: "pc.sync.offset", value: Data([0x01, 0x02, 0x03, 0x04])),
            StatusEntry(key: "", value: Data()),
        ]
        let msg = Message.statusPush(senderID: sender, generation: 42, entries: entries)
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }

    @Test("statusRequest round-trip")
    func statusRequestRoundTrip() throws {
        let sender = PeerID()
        let msg = Message.statusRequest(senderID: sender, correlation: 0xBEEF)
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }

    @Test("statusResponse round-trip")
    func statusResponseRoundTrip() throws {
        let sender = PeerID()
        let entries = [StatusEntry(key: "k", value: Data("v".utf8))]
        let msg = Message.statusResponse(senderID: sender, correlation: 7, generation: 100, entries: entries)
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }

    @Test("statusPush with zero entries")
    func statusPushEmpty() throws {
        let msg = Message.statusPush(senderID: PeerID(), generation: 0, entries: [])
        let encoded = MessageCodec.encode(msg)
        let decoded = try MessageCodec.decode(encoded)
        #expect(decoded == msg)
    }
}
```

- [ ] **Step 5: テスト実行**

Run: `swift test --filter WireStatusTests 2>&1 | tail -10`
Expected: 4 tests passed

- [ ] **Step 6: 全テスト実行で回帰確認**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 41 tests in 9 suites passed`

- [ ] **Step 7: Commit**

```bash
git add Sources/PeerClock/Wire/MessageCodec.swift Tests/PeerClockTests/WireStatusTests.swift
git commit -m "feat(wire): encode/decode status messages"
```

---

## Task 5: StatusKeys constants

**Files:**
- Create: `Sources/PeerClock/Status/StatusKeys.swift`

- [ ] **Step 1: 予約キー定数を定義**

```swift
// Sources/PeerClock/Status/StatusKeys.swift
import Foundation

/// Reserved status keys published automatically by PeerClock under the `pc.*` namespace.
public enum StatusKeys {
    /// Current sync offset in nanoseconds (Int64, binary plist encoded).
    public static let syncOffset = "pc.sync.offset"

    /// Current SyncQuality (binary plist encoded).
    public static let syncQuality = "pc.sync.quality"

    /// Human-readable device name (String, binary plist encoded).
    public static let deviceName = "pc.device.name"

    /// Returns true if the given key is in the reserved `pc.*` namespace.
    public static func isReserved(_ key: String) -> Bool {
        key.hasPrefix("pc.")
    }
}
```

- [ ] **Step 2: ビルド**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/PeerClock/Status/StatusKeys.swift
git commit -m "feat(status): add pc.* reserved key constants"
```

---

## Task 6: StatusRegistry actor (send side)

**Files:**
- Create: `Sources/PeerClock/Status/StatusRegistry.swift`
- Create: `Tests/PeerClockTests/StatusRegistryTests.swift`

- [ ] **Step 1: StatusRegistry を実装**

```swift
// Sources/PeerClock/Status/StatusRegistry.swift
import Foundation

/// Encodes `Codable` values for status transport. Kept separate so tests can
/// verify behaviour without touching the network path.
public enum StatusValueEncoder {
    /// Encodes a Codable value to binary property list bytes.
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode([value])  // plist top-level requires array/dict
    }

    /// Decodes a value previously encoded with `encode(_:)`.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = PropertyListDecoder()
        let wrapper = try decoder.decode([T].self, from: data)
        guard let value = wrapper.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "empty wrapper"))
        }
        return value
    }
}

/// Actor responsible for local status state, debounced flush and generation numbering.
///
/// Contract:
/// - `setStatus` only marks state dirty; actual `STATUS_PUSH` is emitted by the
///   scheduled flush task after `statusSendDebounce` seconds.
/// - `generation` advances once per flush (snapshot-unit), never per key.
public actor StatusRegistry {

    // MARK: - Dependencies

    private let localPeerID: PeerID
    private let debounce: TimeInterval
    private let broadcast: @Sendable (Message) async throws -> Void

    // MARK: - State

    private var entries: [String: Data] = [:]
    private var dirty = false
    private var generation: UInt64 = 0
    private var flushTask: Task<Void, Never>?

    public init(
        localPeerID: PeerID,
        debounce: TimeInterval,
        broadcast: @escaping @Sendable (Message) async throws -> Void
    ) {
        self.localPeerID = localPeerID
        self.debounce = debounce
        self.broadcast = broadcast
    }

    // MARK: - Public API

    /// Sets a raw-bytes status value and schedules a debounced flush.
    public func setStatus(_ data: Data, forKey key: String) {
        entries[key] = data
        dirty = true
        scheduleFlush()
    }

    /// Sets a Codable value (encoded via binary property list).
    public func setStatus<T: Codable & Sendable>(_ value: T, forKey key: String) throws {
        let data = try StatusValueEncoder.encode(value)
        setStatus(data, forKey: key)
    }

    /// Returns a snapshot of the current local entries (for tests/introspection).
    public func snapshot() -> (generation: UInt64, entries: [String: Data]) {
        (generation, entries)
    }

    /// Forces an immediate flush (used on explicit status requests, peer join, etc.).
    public func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await performFlush()
    }

    /// Cancels any pending flush. Called during shutdown.
    public func shutdown() {
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - Internals

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        let delay = debounce
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.performFlush()
        }
    }

    private func performFlush() async {
        flushTask = nil
        guard dirty else { return }
        dirty = false
        generation &+= 1
        let snapshotEntries = entries.map { StatusEntry(key: $0.key, value: $0.value) }
        let message = Message.statusPush(
            senderID: localPeerID,
            generation: generation,
            entries: snapshotEntries
        )
        try? await broadcast(message)
    }
}
```

- [ ] **Step 2: StatusRegistry のテストを書く**

```swift
// Tests/PeerClockTests/StatusRegistryTests.swift
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
            localPeerID: PeerID(),
            debounce: 0.05
        ) { msg in
            await capture.append(msg)
        }

        await registry.setStatus(Data("a".utf8), forKey: "k1")
        await registry.setStatus(Data("b".utf8), forKey: "k2")
        await registry.setStatus(Data("c".utf8), forKey: "k1") // overwrites

        try await Task.sleep(nanoseconds: 150_000_000) // > debounce window
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
            localPeerID: PeerID(),
            debounce: 0.02
        ) { msg in
            await capture.append(msg)
        }

        await registry.setStatus(Data("1".utf8), forKey: "k")
        try await Task.sleep(nanoseconds: 60_000_000)
        await registry.setStatus(Data("2".utf8), forKey: "k")
        try await Task.sleep(nanoseconds: 60_000_000)

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
            localPeerID: PeerID(),
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
            localPeerID: PeerID(),
            debounce: 0.02
        ) { msg in
            await capture.append(msg)
        }

        struct Sample: Codable, Equatable, Sendable {
            let n: Int
            let s: String
        }

        try await registry.setStatus(Sample(n: 42, s: "hi"), forKey: "sample")
        try await Task.sleep(nanoseconds: 80_000_000)

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
            localPeerID: PeerID(),
            debounce: 0.02
        ) { msg in
            await capture.append(msg)
        }

        await registry.flushNow()
        #expect(await capture.all().isEmpty)
    }
}
```

- [ ] **Step 3: テスト実行**

Run: `swift test --filter StatusRegistryTests 2>&1 | tail -10`
Expected: 5 tests passed

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Status/StatusRegistry.swift Tests/PeerClockTests/StatusRegistryTests.swift
git commit -m "feat(status): StatusRegistry actor with debounced flush and snapshot generation"
```

---

## Task 7: StatusReceiver actor (receive side)

**Files:**
- Create: `Sources/PeerClock/Status/StatusReceiver.swift`
- Create: `Tests/PeerClockTests/StatusReceiverTests.swift`

- [ ] **Step 1: StatusReceiver を実装**

```swift
// Sources/PeerClock/Status/StatusReceiver.swift
import Foundation

/// Snapshot of a remote peer's status as observed locally.
public struct RemotePeerStatus: Sendable, Equatable {
    public let peerID: PeerID
    public let generation: UInt64
    public let entries: [String: Data]

    public init(peerID: PeerID, generation: UInt64, entries: [String: Data]) {
        self.peerID = peerID
        self.generation = generation
        self.entries = entries
    }
}

/// Actor holding remote peer status with receive-side debounce.
///
/// Contract:
/// - Drops `STATUS_PUSH` with a `generation` less than or equal to the cached one.
/// - Collapses rapid updates from the same peer into a single event on
///   `updates` stream using `debounce` window.
/// - `status(of:)` returns the last known entries even after disconnect; callers
///   decide staleness via a separate signal (e.g. heartbeat connection state).
public actor StatusReceiver {

    private let debounce: TimeInterval

    private var store: [PeerID: RemotePeerStatus] = [:]
    private var pendingEmit: [PeerID: Task<Void, Never>] = [:]

    private let (stream, continuation) = AsyncStream<RemotePeerStatus>.makeStream()

    public nonisolated var updates: AsyncStream<RemotePeerStatus> { stream }

    public init(debounce: TimeInterval) {
        self.debounce = debounce
    }

    /// Feed an incoming STATUS_PUSH. Returns true if the push was accepted
    /// (not dropped as stale).
    @discardableResult
    public func ingestPush(
        from peerID: PeerID,
        generation: UInt64,
        entries: [StatusEntry]
    ) -> Bool {
        if let existing = store[peerID], existing.generation >= generation {
            return false
        }
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
        let snapshot = RemotePeerStatus(peerID: peerID, generation: generation, entries: dict)
        store[peerID] = snapshot
        scheduleEmit(for: peerID)
        return true
    }

    /// Returns the last known snapshot for a peer, or nil if none has been seen.
    public func status(of peerID: PeerID) -> RemotePeerStatus? {
        store[peerID]
    }

    /// Removes a peer entry (e.g. on hard disconnect cleanup).
    public func forget(_ peerID: PeerID) {
        store.removeValue(forKey: peerID)
        pendingEmit[peerID]?.cancel()
        pendingEmit.removeValue(forKey: peerID)
    }

    public func shutdown() {
        for (_, task) in pendingEmit { task.cancel() }
        pendingEmit.removeAll()
        continuation.finish()
    }

    // MARK: - Debounce

    private func scheduleEmit(for peerID: PeerID) {
        pendingEmit[peerID]?.cancel()
        let delay = debounce
        pendingEmit[peerID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.emit(peerID: peerID)
        }
    }

    private func emit(peerID: PeerID) {
        pendingEmit[peerID] = nil
        guard let snapshot = store[peerID] else { return }
        continuation.yield(snapshot)
    }
}
```

- [ ] **Step 2: StatusReceiver のテストを書く**

```swift
// Tests/PeerClockTests/StatusReceiverTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("StatusReceiver")
struct StatusReceiverTests {

    @Test("Ingests first push and emits after debounce")
    func firstPushEmits() async throws {
        let receiver = StatusReceiver(debounce: 0.05)
        let peer = PeerID()

        let streamTask = Task { () -> RemotePeerStatus? in
            var it = receiver.updates.makeAsyncIterator()
            return await it.next()
        }

        let accepted = await receiver.ingestPush(
            from: peer,
            generation: 1,
            entries: [StatusEntry(key: "k", value: Data("v".utf8))]
        )
        #expect(accepted)

        let emitted = try await withThrowingTaskGroup(of: RemotePeerStatus?.self) { group in
            group.addTask { await streamTask.value }
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #expect(emitted?.peerID == peer)
        #expect(emitted?.generation == 1)
        #expect(emitted?.entries["k"] == Data("v".utf8))
    }

    @Test("Drops older or equal generation")
    func dropsStale() async {
        let receiver = StatusReceiver(debounce: 0.02)
        let peer = PeerID()
        _ = await receiver.ingestPush(from: peer, generation: 5, entries: [])
        let accepted1 = await receiver.ingestPush(from: peer, generation: 5, entries: [])
        let accepted2 = await receiver.ingestPush(from: peer, generation: 4, entries: [])
        let accepted3 = await receiver.ingestPush(from: peer, generation: 6, entries: [])
        #expect(accepted1 == false)
        #expect(accepted2 == false)
        #expect(accepted3 == true)
    }

    @Test("status(of:) returns last known value")
    func lastKnownValue() async {
        let receiver = StatusReceiver(debounce: 0.02)
        let peer = PeerID()
        _ = await receiver.ingestPush(
            from: peer,
            generation: 1,
            entries: [StatusEntry(key: "k", value: Data("v".utf8))]
        )
        let s = await receiver.status(of: peer)
        #expect(s?.entries["k"] == Data("v".utf8))
    }

    @Test("Debounce collapses rapid updates into single event")
    func debounceCollapses() async throws {
        let receiver = StatusReceiver(debounce: 0.08)
        let peer = PeerID()

        // Collect events for a fixed window.
        let collector = Task { () -> [RemotePeerStatus] in
            var out: [RemotePeerStatus] = []
            let deadline = Date().addingTimeInterval(0.4)
            var it = receiver.updates.makeAsyncIterator()
            while Date() < deadline {
                if let next = await it.next() {
                    out.append(next)
                } else {
                    break
                }
            }
            return out
        }

        _ = await receiver.ingestPush(from: peer, generation: 1, entries: [])
        _ = await receiver.ingestPush(from: peer, generation: 2, entries: [])
        _ = await receiver.ingestPush(from: peer, generation: 3, entries: [])

        try await Task.sleep(nanoseconds: 250_000_000)
        collector.cancel()
        let events = await collector.value
        #expect(events.count == 1)
        #expect(events.first?.generation == 3)
    }
}
```

- [ ] **Step 3: テスト実行**

Run: `swift test --filter StatusReceiverTests 2>&1 | tail -10`
Expected: 4 tests passed

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Status/StatusReceiver.swift Tests/PeerClockTests/StatusReceiverTests.swift
git commit -m "feat(status): StatusReceiver actor with generation-based dedup and debounce"
```

---

## Task 8: HeartbeatMonitor actor

**Files:**
- Create: `Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift`
- Create: `Tests/PeerClockTests/HeartbeatMonitorTests.swift`

- [ ] **Step 1: HeartbeatMonitor を実装**

```swift
// Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift
import Foundation

/// Actor tracking per-peer heartbeat freshness and driving connection state
/// transitions. Time is injected via a closure so tests can advance a virtual
/// clock without waiting on real time.
public actor HeartbeatMonitor {

    public struct Event: Sendable, Equatable {
        public let peerID: PeerID
        public let state: ConnectionState
    }

    // MARK: - Dependencies

    private let interval: TimeInterval
    private let degradedAfter: TimeInterval
    private let disconnectedAfter: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let broadcast: @Sendable () async throws -> Void

    // MARK: - State

    private var lastSeen: [PeerID: TimeInterval] = [:]
    private var state: [PeerID: ConnectionState] = [:]
    private var sendTask: Task<Void, Never>?
    private var evalTask: Task<Void, Never>?

    private let (stream, continuation) = AsyncStream<Event>.makeStream()
    public nonisolated var events: AsyncStream<Event> { stream }

    public init(
        interval: TimeInterval,
        degradedAfter: TimeInterval,
        disconnectedAfter: TimeInterval,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        broadcast: @escaping @Sendable () async throws -> Void
    ) {
        self.interval = interval
        self.degradedAfter = degradedAfter
        self.disconnectedAfter = disconnectedAfter
        self.now = now
        self.broadcast = broadcast
    }

    // MARK: - Public API

    /// Starts both the periodic sender and the periodic evaluator.
    public func start() {
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await self.broadcast()
                try? await Task.sleep(nanoseconds: UInt64(await self.interval * 1_000_000_000))
            }
        }
        evalTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.evaluate()
                try? await Task.sleep(nanoseconds: UInt64(await self.interval * 1_000_000_000 / 2))
            }
        }
    }

    public func stop() {
        sendTask?.cancel()
        evalTask?.cancel()
        sendTask = nil
        evalTask = nil
        continuation.finish()
    }

    /// Records an incoming heartbeat from a peer.
    public func heartbeatReceived(from peerID: PeerID) {
        lastSeen[peerID] = now()
        transition(peerID, to: .connected)
    }

    /// Called when a new peer connects (before any heartbeat). Starts tracking.
    public func peerJoined(_ peerID: PeerID) {
        lastSeen[peerID] = now()
        transition(peerID, to: .connected)
    }

    /// Called on explicit disconnect (HELLO dropped, transport error). Forces
    /// the peer to `.disconnected` and stops tracking.
    public func peerLeft(_ peerID: PeerID) {
        lastSeen.removeValue(forKey: peerID)
        transition(peerID, to: .disconnected)
        state.removeValue(forKey: peerID)
    }

    /// Runs one evaluation pass: updates each peer's state based on elapsed time.
    public func evaluate() {
        let current = now()
        for (peerID, seen) in lastSeen {
            let elapsed = current - seen
            let newState: ConnectionState
            if elapsed >= disconnectedAfter {
                newState = .disconnected
            } else if elapsed >= degradedAfter {
                newState = .degraded
            } else {
                newState = .connected
            }
            transition(peerID, to: newState)
        }
    }

    /// Current state for a peer (test introspection).
    public func currentState(of peerID: PeerID) -> ConnectionState? {
        state[peerID]
    }

    // MARK: - Internals

    private func transition(_ peerID: PeerID, to newState: ConnectionState) {
        if state[peerID] == newState { return }
        state[peerID] = newState
        continuation.yield(Event(peerID: peerID, state: newState))
    }
}
```

- [ ] **Step 2: HeartbeatMonitor のテストを書く**

```swift
// Tests/PeerClockTests/HeartbeatMonitorTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("HeartbeatMonitor")
struct HeartbeatMonitorTests {

    actor VirtualClock {
        var t: TimeInterval = 0
        func advance(_ dt: TimeInterval) { t += dt }
        func read() -> TimeInterval { t }
    }

    private func makeMonitor(clock: VirtualClock) -> HeartbeatMonitor {
        HeartbeatMonitor(
            interval: 1.0,
            degradedAfter: 2.0,
            disconnectedAfter: 5.0,
            now: { [clock] in
                // Synchronous accessor: we intentionally read from the actor
                // via a cached value. Tests always call `evaluate()` explicitly
                // after advancing so exact-time reads via Task.sync aren't
                // required; we use DispatchQueue here for a deterministic
                // cross-actor read.
                // NOTE: For simplicity, tests advance the clock then call
                // evaluate(); the monitor's background tasks are not started.
                return clock.unsafeRead()
            },
            broadcast: { }
        )
    }

    @Test("connected → degraded → disconnected on elapsed time")
    func stateTransitions() async {
        let clock = VirtualClock()
        let monitor = HeartbeatMonitor(
            interval: 1.0,
            degradedAfter: 2.0,
            disconnectedAfter: 5.0,
            now: { clock.unsafeRead() },
            broadcast: { }
        )

        let peer = PeerID()
        await monitor.heartbeatReceived(from: peer)
        #expect(await monitor.currentState(of: peer) == .connected)

        await clock.advance(1.0)
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .connected)

        await clock.advance(1.5) // total 2.5s
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .degraded)

        await clock.advance(3.0) // total 5.5s
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .disconnected)
    }

    @Test("Receiving a heartbeat restores to connected")
    func recovery() async {
        let clock = VirtualClock()
        let monitor = HeartbeatMonitor(
            interval: 1.0,
            degradedAfter: 2.0,
            disconnectedAfter: 5.0,
            now: { clock.unsafeRead() },
            broadcast: { }
        )
        let peer = PeerID()
        await monitor.heartbeatReceived(from: peer)

        await clock.advance(2.5)
        await monitor.evaluate()
        #expect(await monitor.currentState(of: peer) == .degraded)

        await monitor.heartbeatReceived(from: peer)
        #expect(await monitor.currentState(of: peer) == .connected)
    }

    @Test("peerLeft forces disconnected regardless of timing")
    func peerLeftForces() async {
        let clock = VirtualClock()
        let monitor = HeartbeatMonitor(
            interval: 1.0,
            degradedAfter: 2.0,
            disconnectedAfter: 5.0,
            now: { clock.unsafeRead() },
            broadcast: { }
        )
        let peer = PeerID()
        await monitor.heartbeatReceived(from: peer)
        await monitor.peerLeft(peer)
        #expect(await monitor.currentState(of: peer) == nil)
    }

    @Test("Event stream emits transitions in order")
    func eventStream() async {
        let clock = VirtualClock()
        let monitor = HeartbeatMonitor(
            interval: 1.0,
            degradedAfter: 2.0,
            disconnectedAfter: 5.0,
            now: { clock.unsafeRead() },
            broadcast: { }
        )
        let peer = PeerID()

        let collector = Task { () -> [HeartbeatMonitor.Event] in
            var events: [HeartbeatMonitor.Event] = []
            var it = monitor.events.makeAsyncIterator()
            while let e = await it.next() {
                events.append(e)
                if events.count == 3 { break }
            }
            return events
        }

        await monitor.heartbeatReceived(from: peer) // connected
        await clock.advance(2.5); await monitor.evaluate() // degraded
        await clock.advance(3.0); await monitor.evaluate() // disconnected

        let events = await collector.value
        #expect(events.map { $0.state } == [.connected, .degraded, .disconnected])
    }
}

// Synchronous peek for tests. Safe because test code sequences access
// explicitly: advance then evaluate, never concurrently.
extension HeartbeatMonitorTests.VirtualClock {
    nonisolated func unsafeRead() -> TimeInterval {
        // Actor-isolated field read via unsafe synchronous bridge for tests.
        // We rely on Swift 6 strict concurrency allowing this only because
        // our test code always awaits `advance` before calling `unsafeRead`.
        var captured: TimeInterval = 0
        let sem = DispatchSemaphore(value: 0)
        Task { captured = await self.read(); sem.signal() }
        sem.wait()
        return captured
    }
}
```

- [ ] **Step 3: テスト実行**

Run: `swift test --filter HeartbeatMonitorTests 2>&1 | tail -15`
Expected: 4 tests passed

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift Tests/PeerClockTests/HeartbeatMonitorTests.swift
git commit -m "feat(heartbeat): HeartbeatMonitor actor with time-based state machine"
```

---

## Task 9: PeerClock facade integration

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`
- Create: `Tests/PeerClockTests/StatusIntegrationTests.swift`

- [ ] **Step 1: PeerClock に新プロパティ・メソッドを配線**

`Sources/PeerClock/PeerClock.swift` の以下の変更を施す:

1. 新しい private プロパティを追加（`private var commandRouter` の直後）:

```swift
    private var statusRegistry: StatusRegistry?
    private var statusReceiver: StatusReceiver?
    private var heartbeatMonitor: HeartbeatMonitor?
    private var statusDispatchTask: Task<Void, Never>?
    private var heartbeatDispatchTask: Task<Void, Never>?
    private var incomingStatusTask: Task<Void, Never>?
```

2. 新しい public API を `commands` ストリームの下に追加:

```swift
    // MARK: - Status API

    /// Sets a raw-bytes status value. Flush is debounced.
    public func setStatus(_ data: Data, forKey key: String) async {
        await statusRegistry?.setStatus(data, forKey: key)
    }

    /// Sets a Codable status value (binary plist encoded). Throws on encode failure.
    public func setStatus<T: Codable & Sendable>(_ value: T, forKey key: String) async throws {
        guard let registry = statusRegistry else { return }
        try await registry.setStatus(value, forKey: key)
    }

    /// Returns the last known status for a peer. The stream caller should
    /// check `connectionState(of:)` to determine staleness.
    public func status(of peer: PeerID) async -> RemotePeerStatus? {
        await statusReceiver?.status(of: peer)
    }

    /// Stream of debounced remote status updates.
    public var statusUpdates: AsyncStream<RemotePeerStatus> {
        statusReceiver?.updates ?? AsyncStream { $0.finish() }
    }

    /// Current connection state for a peer (heartbeat-driven).
    public func connectionState(of peer: PeerID) async -> ConnectionState? {
        await heartbeatMonitor?.currentState(of: peer)
    }

    /// Stream of connection state transitions.
    public var connectionEvents: AsyncStream<HeartbeatMonitor.Event> {
        heartbeatMonitor?.events ?? AsyncStream { $0.finish() }
    }
```

3. `start()` メソッドの内部で transport 初期化の直後に以下を追加（commandRouter 初期化と並行する位置）:

```swift
        // Status registry: debounced flush → transport.broadcast
        let registry = StatusRegistry(
            localPeerID: localPeerID,
            debounce: configuration.statusSendDebounce
        ) { [weak self] message in
            let data = MessageCodec.encode(message)
            try await self?.transport?.broadcast(data)
        }
        self.statusRegistry = registry

        // Status receiver: collects STATUS_PUSH, debounces events
        let receiver = StatusReceiver(debounce: configuration.statusReceiveDebounce)
        self.statusReceiver = receiver

        // Heartbeat: periodic unreliable broadcast + time-based state evaluation
        let heartbeat = HeartbeatMonitor(
            interval: configuration.heartbeatInterval,
            degradedAfter: configuration.degradedAfter,
            disconnectedAfter: configuration.disconnectedAfter
        ) { [weak self] in
            let data = MessageCodec.encode(Message.heartbeat)
            try await self?.transport?.broadcastUnreliable(data)
        }
        self.heartbeatMonitor = heartbeat
        await heartbeat.start()
```

4. `start()` 内の incomingMessages 配信ループ（現状 commandRouter にメッセージを渡している箇所）に、新しいメッセージ種別の振り分けを追加。具体的には、`Sources/PeerClock/PeerClock.swift` の incomingMessages ハンドラ内で以下のケースを追加:

```swift
                    case .heartbeat:
                        await heartbeat.heartbeatReceived(from: senderPeerID)
                    case .statusPush(let senderID, let generation, let entries):
                        _ = await receiver.ingestPush(
                            from: senderID,
                            generation: generation,
                            entries: entries
                        )
                    case .statusRequest, .statusResponse:
                        // Phase 2a では pull API は未配線（push のみで実用十分）。
                        // Phase 2a 後半または Phase 3 で実装。
                        break
```

（現行コードで incomingMessages を decode して分岐している箇所を grep で探し、該当 switch に追加する。現行の switch が網羅的でないなら `default: break` が既にあるはずなので、新ケースは default の前に差し込む。）

5. ピア join/leave に合わせて HeartbeatMonitor に通知する配線を peers ストリーム購読箇所に追加:

```swift
                // peers stream handler の既存処理に追加
                let added = newPeers.subtracting(previousPeers)
                let removed = previousPeers.subtracting(newPeers)
                for p in added { await heartbeat.peerJoined(p) }
                for p in removed { await heartbeat.peerLeft(p) }
```

6. 共通ステータス `pc.device.name` を起動直後に1回だけ設定:

```swift
        let deviceName: String = {
            #if canImport(UIKit)
            return UIDevice.current.name
            #else
            return Host.current().localizedName ?? "Mac"
            #endif
        }()
        try? await registry.setStatus(deviceName, forKey: StatusKeys.deviceName)
```

7. `stop()` メソッドで新 actor を shutdown:

```swift
        await statusRegistry?.shutdown()
        await statusReceiver?.shutdown()
        await heartbeatMonitor?.stop()
        statusRegistry = nil
        statusReceiver = nil
        heartbeatMonitor = nil
```

> **注意**: 実際の Edit ではまず現行 PeerClock.swift 全体を Read し、該当箇所を正確に特定して Edit する。上記は挿入位置の指針。

- [ ] **Step 2: 同期品質を共通ステータスに自動反映するループを追加**

`start()` 内、syncState 購読タスクの既存ハンドラに以下を追加（`.synced(offset, quality)` ケース内）:

```swift
                    // 自動プッシュ: pc.sync.offset / pc.sync.quality
                    let offsetNs = Int64(offset * 1_000_000_000)
                    try? await registry.setStatus(offsetNs, forKey: StatusKeys.syncOffset)
                    try? await registry.setStatus(quality, forKey: StatusKeys.syncQuality)
```

（`SyncQuality` は `Codable` にする必要がある — 次ステップ）

- [ ] **Step 3: SyncQuality を Codable にする**

`Sources/PeerClock/Types.swift` の `SyncQuality` 宣言を `public struct SyncQuality: Sendable, Equatable, Codable {` に変更。

- [ ] **Step 4: ビルド**

Run: `swift build 2>&1 | tail -15`
Expected: `Build complete!`

- [ ] **Step 5: StatusIntegrationTests を書く**

```swift
// Tests/PeerClockTests/StatusIntegrationTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — Status integration")
struct StatusIntegrationTests {

    @Test("Two peers exchange custom status via facade")
    func customStatusRoundTrip() async throws {
        let network = MockNetwork()
        let configA = Configuration(
            statusSendDebounce: 0.03,
            statusReceiveDebounce: 0.03
        )
        let configB = configA

        let a = PeerClock(configuration: configA, transportFactory: { id in
            network.createTransport(for: id)
        })
        let b = PeerClock(configuration: configB, transportFactory: { id in
            network.createTransport(for: id)
        })

        try await a.start()
        try await b.start()

        // Wait for mutual discovery.
        try await waitForPeers(on: a, count: 1)
        try await waitForPeers(on: b, count: 1)

        // A sets a custom status.
        try await a.setStatus("recording", forKey: "com.test.state")

        // B should observe it.
        let observed = try await withTimeout(seconds: 2.0) {
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
        let a = PeerClock(transportFactory: { id in network.createTransport(for: id) })
        let b = PeerClock(transportFactory: { id in network.createTransport(for: id) })

        try await a.start()
        try await b.start()
        try await waitForPeers(on: b, count: 1)

        try await a.setStatus("v1", forKey: "com.test.k")

        // Give the push time to arrive.
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = await b.status(of: a.localPeerID)
        #expect(before?.entries["com.test.k"] != nil)

        await a.stop()
        // Retained snapshot should remain.
        let after = await b.status(of: a.localPeerID)
        #expect(after?.entries["com.test.k"] != nil)

        await b.stop()
    }

    // MARK: - Helpers

    private func waitForPeers(on clock: PeerClock, count: Int, timeout: TimeInterval = 3.0) async throws {
        try await withTimeout(seconds: timeout) {
            for await list in clock.peers {
                if list.count >= count { return }
            }
        }
    }

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
```

- [ ] **Step 6: 統合テスト実行**

Run: `swift test --filter StatusIntegrationTests 2>&1 | tail -10`
Expected: 2 tests passed

- [ ] **Step 7: 全テスト回帰確認**

Run: `swift test 2>&1 | tail -5`
Expected: 全テスト passed（数は Phase 1 の 37 + Phase 2a 追加分）

- [ ] **Step 8: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift Sources/PeerClock/Types.swift Tests/PeerClockTests/StatusIntegrationTests.swift
git commit -m "feat(facade): wire StatusRegistry/Receiver/HeartbeatMonitor into PeerClock"
```

---

## Task 10: Demo app update

**Files:**
- Modify: `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift`
- Modify: `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift`

- [ ] **Step 1: ViewModel にステータス表示と接続状態表示を追加**

`PeerClockViewModel` に以下の observable プロパティを追加:

```swift
    struct RemotePeerView: Identifiable {
        let id: PeerID
        let name: String
        let connectionState: ConnectionState
        let statusSummary: String
    }

    private(set) var remotePeers: [RemotePeerView] = []
```

および、`start()` 内で新しい購読タスクを追加:

```swift
        statusTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await snapshot in clock.statusUpdates {
                await self.handleStatus(snapshot)
            }
        }
        connectionTask = Task { [weak self] in
            guard let self, let clock = await self.clock else { return }
            for await event in clock.connectionEvents {
                await self.handleConnection(event)
            }
        }
```

ハンドラ:

```swift
    private func handleStatus(_ snapshot: RemotePeerStatus) {
        appendLog("Status from \(snapshot.peerID): gen=\(snapshot.generation), keys=\(snapshot.entries.keys.sorted())")
        upsertPeer(snapshot.peerID, statusEntries: snapshot.entries)
    }

    private func handleConnection(_ event: HeartbeatMonitor.Event) {
        appendLog("\(event.peerID): \(event.state)")
        upsertPeer(event.peerID, connectionState: event.state)
    }

    private func upsertPeer(
        _ id: PeerID,
        connectionState: ConnectionState? = nil,
        statusEntries: [String: Data]? = nil
    ) {
        var view = remotePeers.first { $0.id == id } ?? RemotePeerView(
            id: id,
            name: "\(id)",
            connectionState: .connected,
            statusSummary: "-"
        )
        if let cs = connectionState {
            view = RemotePeerView(
                id: view.id,
                name: view.name,
                connectionState: cs,
                statusSummary: view.statusSummary
            )
        }
        if let entries = statusEntries {
            let summary = entries.keys.sorted().prefix(3).joined(separator: ", ")
            view = RemotePeerView(
                id: view.id,
                name: view.name,
                connectionState: view.connectionState,
                statusSummary: summary
            )
        }
        if let idx = remotePeers.firstIndex(where: { $0.id == id }) {
            remotePeers[idx] = view
        } else {
            remotePeers.append(view)
        }
    }
```

- [ ] **Step 2: `stop()` で新タスクをキャンセル**

```swift
        statusTask?.cancel()
        connectionTask?.cancel()
```

- [ ] **Step 3: ContentView に接続状態バッジとステータスサマリを表示**

`Peers (\(viewModel.peers.count))` セクション内の各ピア表示に `RemotePeerView` を使い、接続状態を色付きバッジで、ステータスサマリをテキストで表示。

```swift
            ForEach(viewModel.remotePeers) { peer in
                HStack {
                    Image(systemName: "iphone")
                    Text(peer.name)
                        .font(.system(.caption, design: .monospaced))
                    Spacer()
                    Text("\(peer.connectionState)")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(connectionColor(peer.connectionState).opacity(0.2))
                        .foregroundStyle(connectionColor(peer.connectionState))
                        .clipShape(Capsule())
                }
                if !peer.statusSummary.isEmpty && peer.statusSummary != "-" {
                    Text(peer.statusSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20)
                }
            }
```

およびヘルパ:

```swift
    private func connectionColor(_ state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .degraded: return .orange
        case .disconnected: return .red
        }
    }
```

- [ ] **Step 4: Xcode ビルド**

Run: `xcodebuild -project /Volumes/Dev/DEVELOP/PeerClock/Examples/PeerClockDemo/PeerClockDemo.xcodeproj -scheme PeerClockDemo -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
git commit -m "feat(demo): show per-peer connection state and status summary"
```

---

## Task 11: Simulator end-to-end verification

**Files:** No code changes. Manual verification.

- [ ] **Step 1: 両シミュレータにデプロイ**

```bash
APP="/Users/hakaru/Library/Developer/Xcode/DerivedData/PeerClockDemo-drqkujgbdgpwfdblvgcnuecbddks/Build/Products/Debug-iphonesimulator/PeerClockDemo.app"
xcrun simctl terminate AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl terminate 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl install AF61223F-58C5-48A3-BF21-54F942BA3C32 "$APP"
xcrun simctl install 981BFB44-64A5-476D-88B2-9B34CF8D8762 "$APP"
xcrun simctl launch AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo
xcrun simctl launch 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo
```

- [ ] **Step 2: 動作確認チェックリスト（手動）**

ユーザーに以下の項目を確認してもらう:

1. ✅ 両端で Peers セクションに相手が `connected` バッジ付きで表示される
2. ✅ Log に `pc.device.name` / `pc.sync.offset` / `pc.sync.quality` の status イベントが出る
3. ✅ 片方のアプリを stop → 数秒後にもう片方で `degraded` → `disconnected` バッジに変わる
4. ✅ 再開すると再び `connected` に戻る

結果スクリーンショットを受け取り、問題があればデバッグへ。

- [ ] **Step 3: 問題なければ Phase 2a 完了コミットタグ**

```bash
git tag -a phase-2a-complete -m "Phase 2a: Status sharing + Heartbeat complete"
```

（push はしない）

---

## Self-Review Checklist

- [x] Spec の Phase 2a 節のすべての項目にタスクが対応している
  - Configuration 追加: Task 1
  - unreliable Transport: Task 2
  - 新 Message: Task 3-4
  - StatusRegistry + 送信 debounce + generation: Task 6
  - StatusReceiver + 受信 debounce + 切断後保持: Task 7
  - HeartbeatMonitor + 時間ベース遷移: Task 8
  - facade 配線 + 自動 pc.* プッシュ: Task 9
  - Demo UI 更新: Task 10
  - 実機検証: Task 11
- [x] プレースホルダなし。各コードステップに実コードあり
- [x] 型・メソッド名は一貫（`StatusEntry`, `StatusRegistry`, `StatusReceiver`, `HeartbeatMonitor`, `RemotePeerStatus`, `StatusKeys`, `Event`）
- [x] TDD サイクル: 各新 actor ごとに test-first
- [x] 細かいコミット: 11 タスク × 平均 1-2 コミットで履歴が読みやすい

## 既知のリスク（実装時に注意）

1. **Task 9 の PeerClock.swift 編集**: 現行コードは `@unchecked Sendable` class with NSLock。新 actor との間で `NSLock.withLock` 内から async を呼ぶとデッドロック。Edit 時は既存のロック外で actor を呼ぶよう注意する。
2. **MockNetwork の peers ストリーム遅延**: 既存の `StatusIntegrationTests` のヘルパ `waitForPeers` は MockNetwork の discovery 完了を待つ。もし MockNetwork が最初のイベントで空配列を流すならそれをスキップする分岐が必要。
3. **`SyncQuality: Codable` 化**: Task 9 Step 3。Phase 1 の既存テストで equality を使っている場合は影響ないはずだが、全テスト実行で確認。
4. **HeartbeatMonitor の `interval` 読み取り**: `sendTask` 内の `await self.interval` は actor 内アクセスになるが、`interval` は let なので isolation なしで読めるよう `nonisolated let` にした方が安全。実装時に `nonisolated let interval, degradedAfter, disconnectedAfter` を試す。
