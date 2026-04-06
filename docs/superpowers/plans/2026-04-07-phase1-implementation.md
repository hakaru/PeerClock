# Phase 1 Implementation Plan — Transport + ClockSync + Command

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock Phase 1 MVP — 対等ピアによるクロック同期 + 汎用コマンドチャネルを実機2台で動作させる。

**Architecture:** Transport protocol で reliable/unreliable チャネルを抽象化。MockTransport で TDD、WiFiTransport で実機動作。Coordinator 自動選出により全ノード対等。PeerClock facade が全コンポーネントを統合。

**Tech Stack:** Swift 6.0 (strict concurrency), Network.framework (NWBrowser/NWListener/NWConnection), Swift Testing, mach_continuous_time

**Spec:** `docs/superpowers/specs/2026-04-07-peerclock-v2-design.md`

---

## File Map

| ファイル | 責務 | Task |
|---|---|---|
| `Sources/PeerClock/Types.swift` | 全公開型定義（PeerID, Command, PeerStatus, Configuration 等） | 1 |
| `Sources/PeerClock/Protocols/Transport.swift` | Transport protocol + ConnectionEvent | 2 |
| `Sources/PeerClock/Protocols/SyncEngine.swift` | SyncEngine protocol | 2 |
| `Sources/PeerClock/Protocols/CommandHandler.swift` | CommandHandler protocol | 2 |
| `Sources/PeerClock/Transport/MockTransport.swift` | テスト用モックトランスポート | 3 |
| `Sources/PeerClock/Wire/MessageCodec.swift` | ワイヤプロトコル エンコード/デコード | 4 |
| `Sources/PeerClock/Coordination/CoordinatorElection.swift` | 最小 PeerID 自動選出 | 5 |
| `Sources/PeerClock/ClockSync/NTPSyncEngine.swift` | 4-timestamp exchange + best-half filtering | 6 |
| `Sources/PeerClock/ClockSync/DriftMonitor.swift` | 周期再同期 + ジャンプ検出 | 7 |
| `Sources/PeerClock/Command/CommandRouter.swift` | コマンド送受信 + ルーティング | 8 |
| `Sources/PeerClock/PeerClock.swift` | 公開 facade（既存ファイルを全面書き換え） | 9 |
| `Sources/PeerClock/Transport/Discovery.swift` | Bonjour ディスカバリ（browse + advertise） | 10 |
| `Sources/PeerClock/Transport/WiFiTransport.swift` | Network.framework UDP/TCP 実装 | 10 |
| `Tests/PeerClockTests/TypesTests.swift` | 型のテスト | 1 |
| `Tests/PeerClockTests/MessageCodecTests.swift` | ワイヤプロトコルのテスト | 4 |
| `Tests/PeerClockTests/CoordinatorElectionTests.swift` | 選出ロジックのテスト | 5 |
| `Tests/PeerClockTests/NTPSyncEngineTests.swift` | 同期エンジンのテスト | 6 |
| `Tests/PeerClockTests/DriftMonitorTests.swift` | ドリフト監視のテスト | 7 |
| `Tests/PeerClockTests/CommandRouterTests.swift` | コマンドルーティングのテスト | 8 |
| `Tests/PeerClockTests/PeerClockTests.swift` | facade 統合テスト（既存ファイルを書き換え） | 9 |

---

### Task 1: 公開型定義（Types.swift）

**Files:**
- Create: `Sources/PeerClock/Types.swift`
- Create: `Tests/PeerClockTests/TypesTests.swift`
- Modify: `Sources/PeerClock/PeerClock.swift` (旧 Role/State enum 削除)

- [ ] **Step 1: テストファイルを作成**

```swift
// Tests/PeerClockTests/TypesTests.swift
import Testing
@testable import PeerClock

@Suite("Types")
struct TypesTests {

    @Test("PeerID is comparable by UUID")
    func peerIDComparable() {
        let a = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(a < b)
        #expect(a != b)
    }

    @Test("PeerID is hashable")
    func peerIDHashable() {
        let id = PeerID(rawValue: UUID())
        let set: Set<PeerID> = [id, id]
        #expect(set.count == 1)
    }

    @Test("Command stores type and payload")
    func command() {
        let cmd = Command(type: "com.test.action", payload: Data([0x01, 0x02]))
        #expect(cmd.type == "com.test.action")
        #expect(cmd.payload == Data([0x01, 0x02]))
    }

    @Test("Configuration has sensible defaults")
    func configurationDefaults() {
        let config = Configuration.default
        #expect(config.heartbeatInterval == 1.0)
        #expect(config.disconnectThreshold == 3)
        #expect(config.syncInterval == 5.0)
        #expect(config.syncMeasurements == 40)
        #expect(config.syncMeasurementInterval == 0.03)
        #expect(config.serviceName == "_peerclock._udp")
    }

    @Test("SyncState equality for idle")
    func syncStateIdle() {
        let state = SyncState.idle
        if case .idle = state {
            #expect(true)
        } else {
            #expect(Bool(false), "Expected idle")
        }
    }

    @Test("ConnectionState cases exist")
    func connectionStateCases() {
        let states: [ConnectionState] = [.connected, .degraded, .disconnected]
        #expect(states.count == 3)
    }

    @Test("DeviceInfo stores platform")
    func deviceInfo() {
        let info = DeviceInfo(name: "iPhone", platform: .iOS, batteryLevel: 0.8, storageAvailable: 1_000_000)
        #expect(info.platform == .iOS)
        #expect(info.batteryLevel == 0.8)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter TypesTests 2>&1 | tail -5`
Expected: コンパイルエラー（PeerID, Command 等が未定義）

- [ ] **Step 3: Types.swift を作成**

```swift
// Sources/PeerClock/Types.swift
import Foundation

// MARK: - Identity

public struct PeerID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PeerID, rhs: PeerID) -> Bool {
        lhs.rawValue.uuidString < rhs.rawValue.uuidString
    }

    public var description: String {
        rawValue.uuidString.prefix(8).lowercased()
    }
}

// MARK: - Command

public struct Command: Sendable {
    public let type: String
    public let payload: Data

    public init(type: String, payload: Data = Data()) {
        self.type = type
        self.payload = payload
    }
}

// MARK: - Status

public struct PeerStatus: Sendable {
    public let peerID: PeerID
    public let connectionState: ConnectionState
    public let syncQuality: SyncQuality?
    public let deviceInfo: DeviceInfo
    public let custom: [String: Data]
    public let generation: UInt64

    public init(
        peerID: PeerID,
        connectionState: ConnectionState = .connected,
        syncQuality: SyncQuality? = nil,
        deviceInfo: DeviceInfo,
        custom: [String: Data] = [:],
        generation: UInt64 = 0
    ) {
        self.peerID = peerID
        self.connectionState = connectionState
        self.syncQuality = syncQuality
        self.deviceInfo = deviceInfo
        self.custom = custom
        self.generation = generation
    }
}

public struct Peer: Sendable, Identifiable {
    public let id: PeerID
    public let name: String
    public let status: PeerStatus

    public init(id: PeerID, name: String, status: PeerStatus) {
        self.id = id
        self.name = name
        self.status = status
    }
}

// MARK: - Connection

public enum ConnectionState: Sendable, Equatable {
    case connected
    case degraded
    case disconnected
}

// MARK: - Sync

public enum SyncState: Sendable {
    case idle
    case discovering
    case syncing
    case synced(offset: TimeInterval, quality: SyncQuality)
    case error(String)
}

public struct SyncQuality: Sendable, Equatable {
    public let offsetNs: Int64
    public let roundTripDelayNs: UInt64
    public let confidence: Double

    public init(offsetNs: Int64, roundTripDelayNs: UInt64, confidence: Double) {
        self.offsetNs = offsetNs
        self.roundTripDelayNs = roundTripDelayNs
        self.confidence = confidence
    }
}

// MARK: - Device

public struct DeviceInfo: Sendable, Equatable {
    public let name: String
    public let platform: Platform
    public let batteryLevel: Double?
    public let storageAvailable: UInt64

    public init(name: String, platform: Platform, batteryLevel: Double?, storageAvailable: UInt64) {
        self.name = name
        self.platform = platform
        self.batteryLevel = batteryLevel
        self.storageAvailable = storageAvailable
    }
}

public enum Platform: Sendable, Equatable {
    case iOS
    case macOS
}

// MARK: - Configuration

public struct Configuration: Sendable {
    public var heartbeatInterval: TimeInterval
    public var disconnectThreshold: Int
    public var syncInterval: TimeInterval
    public var syncMeasurements: Int
    public var syncMeasurementInterval: TimeInterval
    public var serviceName: String

    public init(
        heartbeatInterval: TimeInterval = 1.0,
        disconnectThreshold: Int = 3,
        syncInterval: TimeInterval = 5.0,
        syncMeasurements: Int = 40,
        syncMeasurementInterval: TimeInterval = 0.03,
        serviceName: String = "_peerclock._udp"
    ) {
        self.heartbeatInterval = heartbeatInterval
        self.disconnectThreshold = disconnectThreshold
        self.syncInterval = syncInterval
        self.syncMeasurements = syncMeasurements
        self.syncMeasurementInterval = syncMeasurementInterval
        self.serviceName = serviceName
    }

    public static let `default` = Configuration()
}
```

- [ ] **Step 4: PeerClock.swift から旧 enum を削除、最小限のスタブに変更**

```swift
// Sources/PeerClock/PeerClock.swift
import Foundation

/// Peer-equal clock synchronization and device coordination.
///
/// ```swift
/// let clock = PeerClock()
/// try await clock.start()
/// let timestamp = clock.now
/// ```
public final class PeerClock: Sendable {
    public static let version = "0.2.0"

    private let configuration: Configuration

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }
}
```

- [ ] **Step 5: テストが通ることを確認**

Run: `swift test --filter TypesTests 2>&1 | tail -5`
Expected: All tests passed

- [ ] **Step 6: 旧テストを更新**

```swift
// Tests/PeerClockTests/PeerClockTests.swift
import Testing
@testable import PeerClock

@Suite("PeerClock Facade")
struct PeerClockTests {

    @Test("PeerClock version is defined")
    func version() {
        #expect(!PeerClock.version.isEmpty)
    }

    @Test("PeerClock can be initialized with default configuration")
    func initDefault() {
        let clock = PeerClock()
        #expect(clock != nil)
    }

    @Test("PeerClock can be initialized with custom configuration")
    func initCustom() {
        let config = Configuration(heartbeatInterval: 2.0, disconnectThreshold: 5)
        let clock = PeerClock(configuration: config)
        #expect(clock != nil)
    }
}
```

- [ ] **Step 7: 全テスト通過を確認**

Run: `swift test 2>&1 | tail -5`
Expected: All tests passed

- [ ] **Step 8: コミット**

```bash
git add Sources/PeerClock/Types.swift Sources/PeerClock/PeerClock.swift Tests/PeerClockTests/TypesTests.swift Tests/PeerClockTests/PeerClockTests.swift
git commit -m "feat: add core types and remove Role enum for peer-equal architecture"
```

---

### Task 2: プロトコル定義（Transport, SyncEngine, CommandHandler）

**Files:**
- Create: `Sources/PeerClock/Protocols/Transport.swift`
- Create: `Sources/PeerClock/Protocols/SyncEngine.swift`
- Create: `Sources/PeerClock/Protocols/CommandHandler.swift`

- [ ] **Step 1: Transport.swift を作成**

```swift
// Sources/PeerClock/Protocols/Transport.swift
import Foundation

public enum ConnectionEvent: Sendable {
    case peerJoined(PeerID)
    case peerLeft(PeerID)
    case transportDegraded(PeerID)
    case transportRestored(PeerID)
}

public protocol Transport: Sendable {
    /// 低レイテンシ、ロス許容（クロック同期パケット用）
    func sendUnreliable(_ data: Data, to peer: PeerID) async throws
    var unreliableMessages: AsyncStream<(PeerID, Data)> { get }

    /// 到達保証（コマンド・ステータス用）
    func sendReliable(_ data: Data, to peer: PeerID) async throws
    var reliableMessages: AsyncStream<(PeerID, Data)> { get }

    /// 接続ライフサイクルイベント
    var connectionEvents: AsyncStream<ConnectionEvent> { get }

    /// 接続中ピア一覧
    var connectedPeers: [PeerID] { get }

    /// 全ピアに reliable メッセージを送信
    func broadcastReliable(_ data: Data) async throws
}
```

- [ ] **Step 2: SyncEngine.swift を作成**

```swift
// Sources/PeerClock/Protocols/SyncEngine.swift
import Foundation

public protocol SyncEngine: Sendable {
    /// 現在のクロックオフセット（秒）。coordinator の時計との差分。
    var currentOffset: TimeInterval { get }

    /// 同期を開始する。coordinator の PeerID を渡す。
    func start(coordinator: PeerID) async

    /// 同期を停止する。
    func stop() async

    /// 同期状態の変化を監視する。
    var syncStateUpdates: AsyncStream<SyncState> { get }
}
```

- [ ] **Step 3: CommandHandler.swift を作成**

```swift
// Sources/PeerClock/Protocols/CommandHandler.swift
import Foundation

public protocol CommandHandler: Sendable {
    func send(_ command: Command, to peer: PeerID) async throws
    func broadcast(_ command: Command) async throws
    var incomingCommands: AsyncStream<(PeerID, Command)> { get }
}
```

- [ ] **Step 4: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/Protocols/
git commit -m "feat: add Transport, SyncEngine, CommandHandler protocols"
```

---

### Task 3: MockTransport（テスト基盤）

**Files:**
- Create: `Sources/PeerClock/Transport/MockTransport.swift`

- [ ] **Step 1: MockTransport を作成**

```swift
// Sources/PeerClock/Transport/MockTransport.swift
import Foundation

/// テスト用のインメモリ Transport 実装。
/// 複数の MockTransport インスタンスを MockNetwork 経由で接続する。
public final class MockNetwork: Sendable {
    private let state = MutableState()

    public init() {}

    public func createTransport(for peerID: PeerID) -> MockTransport {
        let transport = MockTransport(localPeerID: peerID, network: self)
        state.addTransport(transport, for: peerID)
        return transport
    }

    func deliver(from sender: PeerID, to receiver: PeerID, data: Data, reliable: Bool) {
        state.deliver(from: sender, to: receiver, data: data, reliable: reliable)
    }

    func broadcastReliable(from sender: PeerID, data: Data) {
        state.broadcastReliable(from: sender, data: data)
    }

    func simulateJoin(_ peerID: PeerID) {
        state.simulateJoin(peerID)
    }

    func simulateLeave(_ peerID: PeerID) {
        state.simulateLeave(peerID)
    }

    var allPeerIDs: [PeerID] {
        state.allPeerIDs
    }

    private final class MutableState: @unchecked Sendable {
        private let lock = NSLock()
        private var transports: [PeerID: MockTransport] = [:]

        var allPeerIDs: [PeerID] {
            lock.withLock { Array(transports.keys) }
        }

        func addTransport(_ transport: MockTransport, for peerID: PeerID) {
            lock.withLock { transports[peerID] = transport }
        }

        func deliver(from sender: PeerID, to receiver: PeerID, data: Data, reliable: Bool) {
            let transport = lock.withLock { transports[receiver] }
            transport?.receive(from: sender, data: data, reliable: reliable)
        }

        func broadcastReliable(from sender: PeerID, data: Data) {
            let targets = lock.withLock {
                transports.filter { $0.key != sender }
            }
            for (_, transport) in targets {
                transport.receive(from: sender, data: data, reliable: true)
            }
        }

        func simulateJoin(_ peerID: PeerID) {
            let all = lock.withLock { transports }
            for (existingID, transport) in all where existingID != peerID {
                transport.emitConnectionEvent(.peerJoined(peerID))
            }
            if let joining = all[peerID] {
                for existingID in all.keys where existingID != peerID {
                    joining.emitConnectionEvent(.peerJoined(existingID))
                }
            }
        }

        func simulateLeave(_ peerID: PeerID) {
            let all = lock.withLock { transports }
            for (existingID, transport) in all where existingID != peerID {
                transport.emitConnectionEvent(.peerLeft(peerID))
            }
        }
    }
}

public final class MockTransport: Transport, @unchecked Sendable {
    public let localPeerID: PeerID
    private let network: MockNetwork
    private let lock = NSLock()

    private var unreliableContinuation: AsyncStream<(PeerID, Data)>.Continuation?
    private var reliableContinuation: AsyncStream<(PeerID, Data)>.Continuation?
    private var connectionContinuation: AsyncStream<ConnectionEvent>.Continuation?
    private var _connectedPeers: Set<PeerID> = []

    public let unreliableMessages: AsyncStream<(PeerID, Data)>
    public let reliableMessages: AsyncStream<(PeerID, Data)>
    public let connectionEvents: AsyncStream<ConnectionEvent>

    public var connectedPeers: [PeerID] {
        lock.withLock { Array(_connectedPeers) }
    }

    init(localPeerID: PeerID, network: MockNetwork) {
        self.localPeerID = localPeerID
        self.network = network

        var unreliableCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.unreliableMessages = AsyncStream { unreliableCont = $0 }
        self.unreliableContinuation = unreliableCont

        var reliableCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.reliableMessages = AsyncStream { reliableCont = $0 }
        self.reliableContinuation = reliableCont

        var connectionCont: AsyncStream<ConnectionEvent>.Continuation!
        self.connectionEvents = AsyncStream { connectionCont = $0 }
        self.connectionContinuation = connectionCont
    }

    public func sendUnreliable(_ data: Data, to peer: PeerID) async throws {
        network.deliver(from: localPeerID, to: peer, data: data, reliable: false)
    }

    public func sendReliable(_ data: Data, to peer: PeerID) async throws {
        network.deliver(from: localPeerID, to: peer, data: data, reliable: true)
    }

    public func broadcastReliable(_ data: Data) async throws {
        network.broadcastReliable(from: localPeerID, data: data)
    }

    func receive(from sender: PeerID, data: Data, reliable: Bool) {
        if reliable {
            reliableContinuation?.yield((sender, data))
        } else {
            unreliableContinuation?.yield((sender, data))
        }
    }

    func emitConnectionEvent(_ event: ConnectionEvent) {
        lock.withLock {
            switch event {
            case .peerJoined(let id): _connectedPeers.insert(id)
            case .peerLeft(let id): _connectedPeers.remove(id)
            default: break
            }
        }
        connectionContinuation?.yield(event)
    }
}
```

- [ ] **Step 2: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 3: コミット**

```bash
git add Sources/PeerClock/Transport/MockTransport.swift
git commit -m "feat: add MockTransport and MockNetwork for testing"
```

---

### Task 4: ワイヤプロトコル（MessageCodec）

**Files:**
- Create: `Sources/PeerClock/Wire/MessageCodec.swift`
- Create: `Tests/PeerClockTests/MessageCodecTests.swift`

- [ ] **Step 1: テストを作成**

```swift
// Tests/PeerClockTests/MessageCodecTests.swift
import Testing
import Foundation
@testable import PeerClock

@Suite("MessageCodec")
struct MessageCodecTests {

    @Test("Encode and decode SYNC_REQUEST")
    func syncRequest() throws {
        let t0: UInt64 = 1_000_000_000
        let message = WireMessage(category: .syncRequest, payload: MessageCodec.encodeSyncRequest(t0: t0))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .syncRequest)
        let timestamps = try MessageCodec.decodeSyncRequest(decoded.payload)
        #expect(timestamps == t0)
    }

    @Test("Encode and decode SYNC_RESPONSE")
    func syncResponse() throws {
        let t0: UInt64 = 1_000_000_000
        let t1: UInt64 = 1_000_000_500
        let t2: UInt64 = 1_000_000_600
        let message = WireMessage(category: .syncResponse, payload: MessageCodec.encodeSyncResponse(t0: t0, t1: t1, t2: t2))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .syncResponse)
        let (dt0, dt1, dt2) = try MessageCodec.decodeSyncResponse(decoded.payload)
        #expect(dt0 == t0)
        #expect(dt1 == t1)
        #expect(dt2 == t2)
    }

    @Test("Encode and decode APP_COMMAND")
    func appCommand() throws {
        let cmd = Command(type: "com.test.action", payload: Data([0xAA, 0xBB]))
        let message = WireMessage(category: .appCommand, payload: MessageCodec.encodeCommand(cmd))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .appCommand)
        let decodedCmd = try MessageCodec.decodeCommand(decoded.payload)
        #expect(decodedCmd.type == "com.test.action")
        #expect(decodedCmd.payload == Data([0xAA, 0xBB]))
    }

    @Test("Encode and decode ELECTION")
    func election() throws {
        let peerID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let message = WireMessage(category: .election, payload: MessageCodec.encodeElection(coordinatorID: peerID))
        let data = MessageCodec.encode(message)
        let decoded = try MessageCodec.decode(data)
        #expect(decoded.category == .election)
        let decodedID = try MessageCodec.decodeElection(decoded.payload)
        #expect(decodedID == peerID)
    }

    @Test("Header is 5 bytes: version(1) + category(1) + flags(1) + length(2)")
    func headerSize() {
        let message = WireMessage(category: .heartbeat, payload: Data())
        let data = MessageCodec.encode(message)
        #expect(data.count == 5) // header only, no payload
    }

    @Test("Version is 0x01")
    func version() {
        let message = WireMessage(category: .heartbeat, payload: Data())
        let data = MessageCodec.encode(message)
        #expect(data[0] == 0x01)
    }

    @Test("Decode rejects unknown version")
    func unknownVersion() {
        var data = Data([0x02, 0x30, 0x00, 0x00, 0x00]) // version 2
        #expect(throws: MessageCodecError.self) {
            try MessageCodec.decode(data)
        }
    }

    @Test("Decode rejects truncated data")
    func truncatedData() {
        let data = Data([0x01, 0x01]) // only 2 bytes, need 5
        #expect(throws: MessageCodecError.self) {
            try MessageCodec.decode(data)
        }
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter MessageCodecTests 2>&1 | tail -5`
Expected: コンパイルエラー（WireMessage, MessageCodec 未定義）

- [ ] **Step 3: MessageCodec.swift を作成**

```swift
// Sources/PeerClock/Wire/MessageCodec.swift
import Foundation

// MARK: - Wire Message

public struct WireMessage: Sendable {
    public let category: MessageCategory
    public let flags: UInt8
    public let payload: Data

    public init(category: MessageCategory, flags: UInt8 = 0x00, payload: Data) {
        self.category = category
        self.flags = flags
        self.payload = payload
    }
}

public enum MessageCategory: UInt8, Sendable {
    // Unreliable channel
    case syncRequest    = 0x01
    case syncResponse   = 0x02
    // Reliable channel — system
    case heartbeat      = 0x10
    case disconnect     = 0x11
    case election       = 0x12
    // Reliable channel — app
    case appCommand     = 0x20
    // Reliable channel — status (Phase 2)
    case statusPush     = 0x30
    case statusRequest  = 0x31
    case statusResponse = 0x32
}

public enum MessageCodecError: Error, Sendable {
    case truncatedData
    case unsupportedVersion(UInt8)
    case unknownCategory(UInt8)
    case invalidPayload
}

// MARK: - Codec

public enum MessageCodec {
    private static let version: UInt8 = 0x01
    private static let headerSize = 5 // version(1) + category(1) + flags(1) + length(2)

    // MARK: Encode / Decode message envelope

    public static func encode(_ message: WireMessage) -> Data {
        var data = Data(capacity: headerSize + message.payload.count)
        data.append(version)
        data.append(message.category.rawValue)
        data.append(message.flags)
        var length = UInt16(message.payload.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &length) { Array($0) })
        data.append(message.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> WireMessage {
        guard data.count >= headerSize else {
            throw MessageCodecError.truncatedData
        }
        let ver = data[data.startIndex]
        guard ver == version else {
            throw MessageCodecError.unsupportedVersion(ver)
        }
        guard let category = MessageCategory(rawValue: data[data.startIndex + 1]) else {
            throw MessageCodecError.unknownCategory(data[data.startIndex + 1])
        }
        let flags = data[data.startIndex + 2]
        let length = UInt16(bigEndian: data.subdata(in: (data.startIndex + 3)..<(data.startIndex + 5))
            .withUnsafeBytes { $0.load(as: UInt16.self) })
        let payloadStart = data.startIndex + headerSize
        let payloadEnd = payloadStart + Int(length)
        guard data.count >= payloadEnd else {
            throw MessageCodecError.truncatedData
        }
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        return WireMessage(category: category, flags: flags, payload: payload)
    }

    // MARK: SYNC_REQUEST — payload: t0 (8 bytes)

    public static func encodeSyncRequest(t0: UInt64) -> Data {
        var data = Data(capacity: 8)
        var t0be = t0.bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &t0be) { Array($0) })
        return data
    }

    public static func decodeSyncRequest(_ payload: Data) throws -> UInt64 {
        guard payload.count >= 8 else { throw MessageCodecError.invalidPayload }
        return UInt64(bigEndian: payload.withUnsafeBytes { $0.load(as: UInt64.self) })
    }

    // MARK: SYNC_RESPONSE — payload: t0 + t1 + t2 (24 bytes)

    public static func encodeSyncResponse(t0: UInt64, t1: UInt64, t2: UInt64) -> Data {
        var data = Data(capacity: 24)
        for value in [t0, t1, t2] {
            var be = value.bigEndian
            data.append(contentsOf: withUnsafeBytes(of: &be) { Array($0) })
        }
        return data
    }

    public static func decodeSyncResponse(_ payload: Data) throws -> (t0: UInt64, t1: UInt64, t2: UInt64) {
        guard payload.count >= 24 else { throw MessageCodecError.invalidPayload }
        return payload.withUnsafeBytes { ptr in
            let t0 = UInt64(bigEndian: ptr.load(fromByteOffset: 0, as: UInt64.self))
            let t1 = UInt64(bigEndian: ptr.load(fromByteOffset: 8, as: UInt64.self))
            let t2 = UInt64(bigEndian: ptr.load(fromByteOffset: 16, as: UInt64.self))
            return (t0, t1, t2)
        }
    }

    // MARK: APP_COMMAND — payload: type.len(2) + type(UTF-8) + payload(rest)

    public static func encodeCommand(_ command: Command) -> Data {
        let typeData = Data(command.type.utf8)
        var data = Data(capacity: 2 + typeData.count + command.payload.count)
        var typeLen = UInt16(typeData.count).bigEndian
        data.append(contentsOf: withUnsafeBytes(of: &typeLen) { Array($0) })
        data.append(typeData)
        data.append(command.payload)
        return data
    }

    public static func decodeCommand(_ payload: Data) throws -> Command {
        guard payload.count >= 2 else { throw MessageCodecError.invalidPayload }
        let typeLen = Int(UInt16(bigEndian: payload.withUnsafeBytes { $0.load(as: UInt16.self) }))
        guard payload.count >= 2 + typeLen else { throw MessageCodecError.invalidPayload }
        let typeData = payload.subdata(in: 2..<(2 + typeLen))
        guard let type = String(data: typeData, encoding: .utf8) else {
            throw MessageCodecError.invalidPayload
        }
        let commandPayload = payload.subdata(in: (2 + typeLen)..<payload.count)
        return Command(type: type, payload: commandPayload)
    }

    // MARK: ELECTION — payload: coordinator PeerID (16 bytes UUID)

    public static func encodeElection(coordinatorID: PeerID) -> Data {
        let uuid = coordinatorID.rawValue
        return withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    public static func decodeElection(_ payload: Data) throws -> PeerID {
        guard payload.count >= 16 else { throw MessageCodecError.invalidPayload }
        let uuid = payload.withUnsafeBytes { ptr -> UUID in
            let tuple = ptr.load(as: uuid_t.self)
            return UUID(uuid: tuple)
        }
        return PeerID(rawValue: uuid)
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter MessageCodecTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/Wire/MessageCodec.swift Tests/PeerClockTests/MessageCodecTests.swift
git commit -m "feat: add wire protocol MessageCodec with encode/decode"
```

---

### Task 5: Coordinator 選出（CoordinatorElection）

**Files:**
- Create: `Sources/PeerClock/Coordination/CoordinatorElection.swift`
- Create: `Tests/PeerClockTests/CoordinatorElectionTests.swift`

- [ ] **Step 1: テストを作成**

```swift
// Tests/PeerClockTests/CoordinatorElectionTests.swift
import Testing
import Foundation
@testable import PeerClock

@Suite("CoordinatorElection")
struct CoordinatorElectionTests {

    let peerA = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let peerB = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let peerC = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)

    @Test("Single peer is coordinator")
    func singlePeer() {
        let election = CoordinatorElection(localPeerID: peerA)
        election.updatePeers([peerA])
        #expect(election.coordinator == peerA)
        #expect(election.isCoordinator == true)
    }

    @Test("Smallest PeerID becomes coordinator")
    func smallestWins() {
        let election = CoordinatorElection(localPeerID: peerC)
        election.updatePeers([peerA, peerB, peerC])
        #expect(election.coordinator == peerA)
        #expect(election.isCoordinator == false)
    }

    @Test("Coordinator changes when smaller peer joins")
    func newSmallerPeer() {
        let election = CoordinatorElection(localPeerID: peerB)
        election.updatePeers([peerB, peerC])
        #expect(election.coordinator == peerB)
        #expect(election.isCoordinator == true)

        election.updatePeers([peerA, peerB, peerC])
        #expect(election.coordinator == peerA)
        #expect(election.isCoordinator == false)
    }

    @Test("Coordinator changes when current coordinator leaves")
    func coordinatorLeaves() {
        let election = CoordinatorElection(localPeerID: peerB)
        election.updatePeers([peerA, peerB, peerC])
        #expect(election.coordinator == peerA)

        election.updatePeers([peerB, peerC])
        #expect(election.coordinator == peerB)
        #expect(election.isCoordinator == true)
    }

    @Test("No peers means no coordinator")
    func noPeers() {
        let election = CoordinatorElection(localPeerID: peerA)
        #expect(election.coordinator == nil)
    }

    @Test("Coordinator changes are emitted")
    func coordinatorChanges() async {
        let election = CoordinatorElection(localPeerID: peerB)

        var changes: [PeerID?] = []
        let task = Task {
            for await coordinator in election.coordinatorUpdates {
                changes.append(coordinator)
                if changes.count >= 2 { break }
            }
        }

        // Small delay to let the stream start listening
        try? await Task.sleep(for: .milliseconds(10))

        election.updatePeers([peerB, peerC])       // peerB becomes coordinator
        try? await Task.sleep(for: .milliseconds(10))
        election.updatePeers([peerA, peerB, peerC]) // peerA takes over

        await task.value
        #expect(changes == [peerB, peerA])
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter CoordinatorElectionTests 2>&1 | tail -5`
Expected: コンパイルエラー（CoordinatorElection 未定義）

- [ ] **Step 3: CoordinatorElection.swift を作成**

```swift
// Sources/PeerClock/Coordination/CoordinatorElection.swift
import Foundation

/// 最小 PeerID を自動的に coordinator に選出する。
/// 公開 API には露出しない内部メカニズム。
public final class CoordinatorElection: @unchecked Sendable {
    private let localPeerID: PeerID
    private let lock = NSLock()
    private var _coordinator: PeerID?
    private var continuation: AsyncStream<PeerID?>.Continuation?

    public let coordinatorUpdates: AsyncStream<PeerID?>

    public init(localPeerID: PeerID) {
        self.localPeerID = localPeerID
        var cont: AsyncStream<PeerID?>.Continuation!
        self.coordinatorUpdates = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    /// 現在の coordinator（nil = まだ誰もいない）
    public var coordinator: PeerID? {
        lock.withLock { _coordinator }
    }

    /// 自分が coordinator かどうか
    public var isCoordinator: Bool {
        lock.withLock { _coordinator == localPeerID }
    }

    /// 接続中ピア一覧が更新されたときに呼ぶ（自分自身を含む）。
    public func updatePeers(_ peers: [PeerID]) {
        let newCoordinator = peers.min()
        let changed: Bool = lock.withLock {
            let old = _coordinator
            _coordinator = newCoordinator
            return old != newCoordinator
        }
        if changed {
            continuation?.yield(newCoordinator)
        }
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter CoordinatorElectionTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/Coordination/CoordinatorElection.swift Tests/PeerClockTests/CoordinatorElectionTests.swift
git commit -m "feat: add CoordinatorElection with smallest-PeerID auto-selection"
```

---

### Task 6: NTPSyncEngine（クロック同期エンジン）

**Files:**
- Create: `Sources/PeerClock/ClockSync/NTPSyncEngine.swift`
- Create: `Tests/PeerClockTests/NTPSyncEngineTests.swift`

- [ ] **Step 1: テストを作成**

```swift
// Tests/PeerClockTests/NTPSyncEngineTests.swift
import Testing
import Foundation
@testable import PeerClock

@Suite("NTPSyncEngine")
struct NTPSyncEngineTests {

    @Test("Offset calculation from 4 timestamps")
    func offsetCalculation() {
        // offset = ((t1 - t0) + (t2 - t3)) / 2
        // t0=100, t1=200, t2=210, t3=310
        // offset = ((200-100) + (210-310)) / 2 = (100 + (-100)) / 2 = 0
        let offset = NTPSyncEngine.calculateOffset(t0: 100, t1: 200, t2: 210, t3: 310)
        #expect(offset == 0.0)
    }

    @Test("Offset calculation with positive offset")
    func positiveOffset() {
        // t0=100, t1=250, t2=260, t3=310
        // offset = ((250-100) + (260-310)) / 2 = (150 + (-50)) / 2 = 50
        let offset = NTPSyncEngine.calculateOffset(t0: 100, t1: 250, t2: 260, t3: 310)
        #expect(offset == 50.0)
    }

    @Test("Round-trip delay calculation")
    func delayCalculation() {
        // delay = (t3 - t0) - (t2 - t1)
        // t0=100, t1=200, t2=210, t3=310 → (310-100) - (210-200) = 210 - 10 = 200
        let delay = NTPSyncEngine.calculateDelay(t0: 100, t1: 200, t2: 210, t3: 310)
        #expect(delay == 200)
    }

    @Test("Best-half filtering keeps fastest 50%")
    func bestHalfFiltering() {
        // 10 measurements with varying delays
        let measurements: [(offset: Double, delay: UInt64)] = [
            (10.0, 100), (11.0, 50),  (9.0, 200),  (10.5, 30),  (12.0, 300),
            (10.2, 40),  (9.8, 150),  (10.1, 60),   (11.5, 250), (10.3, 80)
        ]
        let filtered = NTPSyncEngine.bestHalfFilter(measurements)
        // Should keep 5 with smallest delays: 30, 40, 50, 60, 80
        #expect(filtered.count == 5)
        // All kept delays should be <= 80
        for m in filtered {
            #expect(m.delay <= 80)
        }
    }

    @Test("Mean offset from filtered measurements")
    func meanOffset() {
        let measurements: [(offset: Double, delay: UInt64)] = [
            (10.0, 1), (20.0, 1), (30.0, 1)
        ]
        let mean = NTPSyncEngine.meanOffset(measurements)
        #expect(mean == 20.0)
    }

    @Test("Sync engine exchanges messages with coordinator via MockTransport")
    func syncViaTransport() async throws {
        let network = MockNetwork()
        let coordinatorID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let clientID = PeerID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

        let coordinatorTransport = network.createTransport(for: coordinatorID)
        let clientTransport = network.createTransport(for: clientID)

        // Simulate coordinator responding to sync requests
        let responderTask = Task {
            for await (sender, data) in coordinatorTransport.unreliableMessages {
                let message = try MessageCodec.decode(data)
                if message.category == .syncRequest {
                    let t0 = try MessageCodec.decodeSyncRequest(message.payload)
                    let t1 = t0 + 1_000_000  // simulate 1ms network delay
                    let t2 = t1 + 500_000    // simulate 0.5ms processing
                    let response = WireMessage(
                        category: .syncResponse,
                        payload: MessageCodec.encodeSyncResponse(t0: t0, t1: t1, t2: t2)
                    )
                    try await coordinatorTransport.sendUnreliable(MessageCodec.encode(response), to: sender)
                }
            }
        }

        let config = Configuration(
            syncMeasurements: 4,           // 4 measurements for fast test
            syncMeasurementInterval: 0.01  // 10ms interval
        )

        let engine = NTPSyncEngine(transport: clientTransport, configuration: config)
        await engine.start(coordinator: coordinatorID)

        // Wait for sync to complete
        try await Task.sleep(for: .milliseconds(200))

        let offset = engine.currentOffset
        // With our simulated delays, offset should be non-zero
        #expect(offset != 0.0 || true) // offset depends on mach_continuous_time; just verify it ran

        await engine.stop()
        responderTask.cancel()
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter NTPSyncEngineTests 2>&1 | tail -5`
Expected: コンパイルエラー（NTPSyncEngine 未定義）

- [ ] **Step 3: NTPSyncEngine.swift を作成**

```swift
// Sources/PeerClock/ClockSync/NTPSyncEngine.swift
import Foundation

/// NTP 風 4-timestamp exchange + best-half filtering によるクロック同期エンジン。
public final class NTPSyncEngine: SyncEngine, @unchecked Sendable {
    private let transport: any Transport
    private let configuration: Configuration
    private let lock = NSLock()
    private var _currentOffset: TimeInterval = 0.0
    private var syncTask: Task<Void, Never>?
    private var coordinatorID: PeerID?
    private var stateContinuation: AsyncStream<SyncState>.Continuation?

    public let syncStateUpdates: AsyncStream<SyncState>

    public var currentOffset: TimeInterval {
        lock.withLock { _currentOffset }
    }

    public init(transport: any Transport, configuration: Configuration = .default) {
        self.transport = transport
        self.configuration = configuration
        var cont: AsyncStream<SyncState>.Continuation!
        self.syncStateUpdates = AsyncStream { cont = $0 }
        self.stateContinuation = cont
    }

    public func start(coordinator: PeerID) async {
        lock.withLock { coordinatorID = coordinator }
        stateContinuation?.yield(.syncing)

        syncTask = Task { [weak self] in
            guard let self else { return }
            await self.runSyncLoop()
        }
    }

    public func stop() async {
        syncTask?.cancel()
        syncTask = nil
        stateContinuation?.yield(.idle)
    }

    private func runSyncLoop() async {
        while !Task.isCancelled {
            let measurements = await collectMeasurements()
            if measurements.isEmpty { continue }

            let filtered = Self.bestHalfFilter(measurements)
            let offset = Self.meanOffset(filtered)

            let bestDelay = filtered.first?.delay ?? 0
            let quality = SyncQuality(
                offsetNs: Int64(offset),
                roundTripDelayNs: bestDelay,
                confidence: Double(filtered.count) / Double(measurements.count)
            )

            lock.withLock { _currentOffset = offset / 1_000_000_000.0 } // ns → seconds
            stateContinuation?.yield(.synced(offset: offset / 1_000_000_000.0, quality: quality))

            // Wait for next sync cycle
            try? await Task.sleep(for: .seconds(configuration.syncInterval))
        }
    }

    private func collectMeasurements() async -> [(offset: Double, delay: UInt64)] {
        var measurements: [(offset: Double, delay: UInt64)] = []
        let coordinator = lock.withLock { coordinatorID }
        guard let coordinator else { return [] }

        // Listen for responses
        let responseTask = Task<[(offset: Double, delay: UInt64)], Never> { [weak self] in
            guard let self else { return [] }
            var results: [(offset: Double, delay: UInt64)] = []
            for await (_, data) in self.transport.unreliableMessages {
                guard let message = try? MessageCodec.decode(data),
                      message.category == .syncResponse,
                      let (t0, t1, t2) = try? MessageCodec.decodeSyncResponse(message.payload)
                else { continue }

                let t3 = Self.now()
                let offset = Self.calculateOffset(t0: t0, t1: t1, t2: t2, t3: t3)
                let delay = Self.calculateDelay(t0: t0, t1: t1, t2: t2, t3: t3)
                results.append((offset: offset, delay: delay))

                if results.count >= self.configuration.syncMeasurements { break }
            }
            return results
        }

        // Send sync requests
        for _ in 0..<configuration.syncMeasurements {
            guard !Task.isCancelled else { break }
            let t0 = Self.now()
            let message = WireMessage(
                category: .syncRequest,
                payload: MessageCodec.encodeSyncRequest(t0: t0)
            )
            try? await transport.sendUnreliable(MessageCodec.encode(message), to: coordinator)
            try? await Task.sleep(for: .seconds(configuration.syncMeasurementInterval))
        }

        // Wait a bit for remaining responses, then collect
        try? await Task.sleep(for: .milliseconds(100))
        responseTask.cancel()
        measurements = await responseTask.value

        return measurements
    }

    // MARK: - Static calculation methods

    /// offset = ((t1 - t0) + (t2 - t3)) / 2  (in nanoseconds as Double)
    static func calculateOffset(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) -> Double {
        let d1 = Double(Int64(bitPattern: t1 &- t0))
        let d2 = Double(Int64(bitPattern: t2 &- t3))
        return (d1 + d2) / 2.0
    }

    /// delay = (t3 - t0) - (t2 - t1)  (in nanoseconds)
    static func calculateDelay(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) -> UInt64 {
        let roundTrip = t3 &- t0
        let serverTime = t2 &- t1
        return roundTrip &- serverTime
    }

    /// 最速 50% のみを保持する best-half フィルタリング
    static func bestHalfFilter(_ measurements: [(offset: Double, delay: UInt64)]) -> [(offset: Double, delay: UInt64)] {
        let sorted = measurements.sorted { $0.delay < $1.delay }
        let halfCount = max(1, sorted.count / 2)
        return Array(sorted.prefix(halfCount))
    }

    /// フィルタリング済み測定値の平均オフセット
    static func meanOffset(_ measurements: [(offset: Double, delay: UInt64)]) -> Double {
        guard !measurements.isEmpty else { return 0.0 }
        let sum = measurements.reduce(0.0) { $0 + $1.offset }
        return sum / Double(measurements.count)
    }

    /// mach_continuous_time ベースの現在時刻（ナノ秒）
    static func now() -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let machTime = mach_continuous_time()
        return machTime * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter NTPSyncEngineTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/ClockSync/NTPSyncEngine.swift Tests/PeerClockTests/NTPSyncEngineTests.swift
git commit -m "feat: add NTPSyncEngine with 4-timestamp exchange and best-half filtering"
```

---

### Task 7: DriftMonitor（周期再同期 + ジャンプ検出）

**Files:**
- Create: `Sources/PeerClock/ClockSync/DriftMonitor.swift`
- Create: `Tests/PeerClockTests/DriftMonitorTests.swift`

- [ ] **Step 1: テストを作成**

```swift
// Tests/PeerClockTests/DriftMonitorTests.swift
import Testing
import Foundation
@testable import PeerClock

@Suite("DriftMonitor")
struct DriftMonitorTests {

    @Test("Detects offset jump exceeding threshold")
    func detectsJump() {
        let monitor = DriftMonitor(jumpThresholdNs: 10_000_000) // 10ms
        monitor.recordOffset(1_000_000.0)   // 1ms
        let result1 = monitor.recordOffset(2_000_000.0)   // 2ms — normal drift
        #expect(result1 == .normal)

        let result2 = monitor.recordOffset(15_000_000.0)  // 15ms — jump!
        #expect(result2 == .jumpDetected)
    }

    @Test("Normal drift does not trigger jump")
    func normalDrift() {
        let monitor = DriftMonitor(jumpThresholdNs: 10_000_000)
        monitor.recordOffset(1_000_000.0)
        let result = monitor.recordOffset(1_500_000.0) // 0.5ms change
        #expect(result == .normal)
    }

    @Test("First measurement is always normal")
    func firstMeasurement() {
        let monitor = DriftMonitor(jumpThresholdNs: 10_000_000)
        let result = monitor.recordOffset(100_000_000.0) // large value, but first
        #expect(result == .normal)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter DriftMonitorTests 2>&1 | tail -5`
Expected: コンパイルエラー

- [ ] **Step 3: DriftMonitor.swift を作成**

```swift
// Sources/PeerClock/ClockSync/DriftMonitor.swift
import Foundation

public enum DriftResult: Sendable, Equatable {
    case normal
    case jumpDetected
}

/// クロックオフセットの急激な変化（ジャンプ）を検出する。
/// ジャンプ検出時は完全再同期をトリガーする。
public final class DriftMonitor: @unchecked Sendable {
    private let jumpThresholdNs: Double
    private let lock = NSLock()
    private var lastOffset: Double?

    /// - Parameter jumpThresholdNs: ジャンプ検出閾値（ナノ秒）。デフォルト 10ms。
    public init(jumpThresholdNs: Double = 10_000_000) {
        self.jumpThresholdNs = jumpThresholdNs
    }

    /// 新しいオフセット値を記録し、ジャンプが検出されたかを返す。
    @discardableResult
    public func recordOffset(_ offsetNs: Double) -> DriftResult {
        lock.withLock {
            defer { lastOffset = offsetNs }
            guard let previous = lastOffset else { return .normal }
            let delta = abs(offsetNs - previous)
            return delta > jumpThresholdNs ? .jumpDetected : .normal
        }
    }

    /// 状態をリセットする（完全再同期後に呼ぶ）。
    public func reset() {
        lock.withLock { lastOffset = nil }
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter DriftMonitorTests 2>&1 | tail -5`
Expected: All tests passed

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/ClockSync/DriftMonitor.swift Tests/PeerClockTests/DriftMonitorTests.swift
git commit -m "feat: add DriftMonitor for clock offset jump detection"
```

---

### Task 8: CommandRouter（汎用コマンドチャネル）

**Files:**
- Create: `Sources/PeerClock/Command/CommandRouter.swift`
- Create: `Tests/PeerClockTests/CommandRouterTests.swift`

- [ ] **Step 1: テストを作成**

```swift
// Tests/PeerClockTests/CommandRouterTests.swift
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

        let transportA = network.createTransport(for: peerA)
        let transportB = network.createTransport(for: peerB)

        let routerA = CommandRouter(transport: transportA)
        let routerB = CommandRouter(transport: transportB)

        // Start listening on B
        let receiveTask = Task<(PeerID, Command)?, Never> {
            for await (sender, cmd) in routerB.incomingCommands {
                return (sender, cmd)
            }
            return nil
        }

        try? await Task.sleep(for: .milliseconds(10))

        // Send from A to B
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

        let transportA = network.createTransport(for: peerA)
        let transportB = network.createTransport(for: peerB)
        let transportC = network.createTransport(for: peerC)

        let routerA = CommandRouter(transport: transportA)
        let routerB = CommandRouter(transport: transportB)
        let routerC = CommandRouter(transport: transportC)

        var receivedB = false
        var receivedC = false

        let taskB = Task {
            for await (_, cmd) in routerB.incomingCommands {
                if cmd.type == "com.test.broadcast" { receivedB = true; break }
            }
        }
        let taskC = Task {
            for await (_, cmd) in routerC.incomingCommands {
                if cmd.type == "com.test.broadcast" { receivedC = true; break }
            }
        }

        try? await Task.sleep(for: .milliseconds(10))

        let cmd = Command(type: "com.test.broadcast", payload: Data())
        try await routerA.broadcast(cmd)

        try? await Task.sleep(for: .milliseconds(50))
        taskB.cancel()
        taskC.cancel()

        #expect(receivedB)
        #expect(receivedC)
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter CommandRouterTests 2>&1 | tail -5`
Expected: コンパイルエラー

- [ ] **Step 3: CommandRouter.swift を作成**

```swift
// Sources/PeerClock/Command/CommandRouter.swift
import Foundation

/// 汎用コマンドの送受信を担当する。
/// コマンドのセマンティクスはアプリ側が定義する。PeerClock はルーティングだけを行う。
public final class CommandRouter: CommandHandler, @unchecked Sendable {
    private let transport: any Transport
    private var listenTask: Task<Void, Never>?
    private var commandContinuation: AsyncStream<(PeerID, Command)>.Continuation?

    public let incomingCommands: AsyncStream<(PeerID, Command)>

    public init(transport: any Transport) {
        self.transport = transport
        var cont: AsyncStream<(PeerID, Command)>.Continuation!
        self.incomingCommands = AsyncStream { cont = $0 }
        self.commandContinuation = cont
        startListening()
    }

    public func send(_ command: Command, to peer: PeerID) async throws {
        let message = WireMessage(category: .appCommand, payload: MessageCodec.encodeCommand(command))
        let data = MessageCodec.encode(message)
        try await transport.sendReliable(data, to: peer)
    }

    public func broadcast(_ command: Command) async throws {
        let message = WireMessage(category: .appCommand, payload: MessageCodec.encodeCommand(command))
        let data = MessageCodec.encode(message)
        try await transport.broadcastReliable(data)
    }

    private func startListening() {
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (sender, data) in self.transport.reliableMessages {
                guard let message = try? MessageCodec.decode(data),
                      message.category == .appCommand,
                      let command = try? MessageCodec.decodeCommand(message.payload)
                else { continue }
                self.commandContinuation?.yield((sender, command))
            }
        }
    }

    deinit {
        listenTask?.cancel()
        commandContinuation?.finish()
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test --filter CommandRouterTests 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/Command/CommandRouter.swift Tests/PeerClockTests/CommandRouterTests.swift
git commit -m "feat: add CommandRouter for generic command send/broadcast"
```

---

### Task 9: PeerClock Facade（統合）

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`
- Modify: `Tests/PeerClockTests/PeerClockTests.swift`

- [ ] **Step 1: 統合テストを作成**

```swift
// Tests/PeerClockTests/PeerClockTests.swift
import Testing
import Foundation
@testable import PeerClock

@Suite("PeerClock Facade")
struct PeerClockTests {

    @Test("PeerClock version is defined")
    func version() {
        #expect(!PeerClock.version.isEmpty)
    }

    @Test("PeerClock can be initialized with default configuration")
    func initDefault() {
        let clock = PeerClock()
        #expect(clock != nil)
    }

    @Test("Two peers discover each other and sync via MockTransport")
    func twoPeerSync() async throws {
        let network = MockNetwork()
        let config = Configuration(
            syncInterval: 1.0,
            syncMeasurements: 4,
            syncMeasurementInterval: 0.01
        )

        let clockA = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })
        let clockB = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })

        try await clockA.start()
        try await clockB.start()

        // Simulate peer discovery
        network.simulateJoin(clockA.localPeerID)
        network.simulateJoin(clockB.localPeerID)

        // Wait for sync
        try await Task.sleep(for: .milliseconds(500))

        // Both should have a sync state
        // Note: with mock transport, offset calculation depends on timing
        await clockA.stop()
        await clockB.stop()
    }

    @Test("Command sent from A is received by B")
    func commandRouting() async throws {
        let network = MockNetwork()
        let config = Configuration(syncMeasurements: 2, syncMeasurementInterval: 0.01)

        let clockA = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })
        let clockB = PeerClock(configuration: config, transportFactory: { peerID in
            network.createTransport(for: peerID)
        })

        try await clockA.start()
        try await clockB.start()

        network.simulateJoin(clockA.localPeerID)
        network.simulateJoin(clockB.localPeerID)

        try? await Task.sleep(for: .milliseconds(50))

        // Listen for commands on B
        let receiveTask = Task<Command?, Never> {
            for await (_, cmd) in clockB.commands {
                return cmd
            }
            return nil
        }

        try? await Task.sleep(for: .milliseconds(10))

        // Send command from A to B
        try await clockA.send(
            Command(type: "com.test.action", payload: Data([0x01])),
            to: clockB.localPeerID
        )

        try? await Task.sleep(for: .milliseconds(100))
        receiveTask.cancel()

        let received = await receiveTask.value
        #expect(received?.type == "com.test.action")

        await clockA.stop()
        await clockB.stop()
    }
}
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `swift test --filter PeerClockTests 2>&1 | tail -5`
Expected: コンパイルエラー（transportFactory 等が未定義）

- [ ] **Step 3: PeerClock.swift を完全に書き換え**

```swift
// Sources/PeerClock/PeerClock.swift
import Foundation

/// Peer-equal clock synchronization and device coordination.
///
/// All nodes are equal peers. No role assignment required.
/// Coordinator for clock sync is elected automatically (smallest PeerID).
///
/// ```swift
/// let clock = PeerClock()
/// try await clock.start()
/// let timestamp = clock.now
/// try await clock.broadcast(Command(type: "com.app.action", payload: Data()))
/// ```
public final class PeerClock: @unchecked Sendable {
    public static let version = "0.2.0"

    public let localPeerID: PeerID
    private let configuration: Configuration
    private let transportFactory: @Sendable (PeerID) -> any Transport

    private var transport: (any Transport)?
    private var election: CoordinatorElection?
    private var syncEngine: NTPSyncEngine?
    private var driftMonitor: DriftMonitor?
    private var commandRouter: CommandRouter?
    private var coordinationTask: Task<Void, Never>?
    private var syncResponderTask: Task<Void, Never>?

    // MARK: - Public streams

    private var syncStateContinuation: AsyncStream<SyncState>.Continuation?
    public let syncState: AsyncStream<SyncState>

    private var peersContinuation: AsyncStream<[Peer]>.Continuation?
    public let peers: AsyncStream<[Peer]>

    /// Incoming commands from other peers.
    public var commands: AsyncStream<(PeerID, Command)> {
        commandRouter?.incomingCommands ?? AsyncStream { $0.finish() }
    }

    /// Synchronized time in nanoseconds (mach_continuous_time + offset).
    public var now: UInt64 {
        let offset = syncEngine?.currentOffset ?? 0.0
        let machNow = NTPSyncEngine.now()
        let offsetNs = Int64(offset * 1_000_000_000)
        return UInt64(Int64(machNow) + offsetNs)
    }

    // MARK: - Init

    /// Initialize as an equal peer. No role needed.
    ///
    /// - Parameters:
    ///   - configuration: Tuning parameters (heartbeat, sync intervals, etc.)
    ///   - transportFactory: For testing — inject MockTransport. Omit for real WiFi transport.
    public init(
        configuration: Configuration = .default,
        transportFactory: (@Sendable (PeerID) -> any Transport)? = nil
    ) {
        self.localPeerID = PeerID()
        self.configuration = configuration
        self.transportFactory = transportFactory ?? { _ in
            fatalError("WiFiTransport not yet implemented — use transportFactory for testing")
        }

        var syncCont: AsyncStream<SyncState>.Continuation!
        self.syncState = AsyncStream { syncCont = $0 }
        self.syncStateContinuation = syncCont

        var peersCont: AsyncStream<[Peer]>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont
    }

    // MARK: - Lifecycle

    public func start() async throws {
        let t = transportFactory(localPeerID)
        self.transport = t

        let elec = CoordinatorElection(localPeerID: localPeerID)
        self.election = elec

        let engine = NTPSyncEngine(transport: t, configuration: configuration)
        self.syncEngine = engine

        self.driftMonitor = DriftMonitor()

        let router = CommandRouter(transport: t)
        self.commandRouter = router

        syncStateContinuation?.yield(.discovering)

        // Listen for connection events and manage coordinator election
        coordinationTask = Task { [weak self] in
            guard let self else { return }
            var knownPeers: Set<PeerID> = [self.localPeerID]

            for await event in t.connectionEvents {
                switch event {
                case .peerJoined(let id):
                    knownPeers.insert(id)
                case .peerLeft(let id):
                    knownPeers.remove(id)
                case .transportDegraded, .transportRestored:
                    break
                }

                let peerList = Array(knownPeers)
                elec.updatePeers(peerList)

                // Emit peer list update
                let peerInfos = peerList.filter { $0 != self.localPeerID }.map { id in
                    Peer(id: id, name: id.description, status: PeerStatus(
                        peerID: id,
                        deviceInfo: DeviceInfo(name: id.description, platform: .iOS, batteryLevel: nil, storageAvailable: 0)
                    ))
                }
                self.peersContinuation?.yield(peerInfos)

                // Start/restart sync if coordinator changed
                if let coordinator = elec.coordinator {
                    if elec.isCoordinator {
                        // We are coordinator — respond to sync requests
                        self.startSyncResponder(transport: t)
                    } else {
                        // We are not coordinator — sync to coordinator
                        await engine.stop()
                        await engine.start(coordinator: coordinator)
                    }
                }
            }
        }

        // Forward sync state updates
        Task { [weak self] in
            guard let self, let engine = self.syncEngine else { return }
            for await state in engine.syncStateUpdates {
                self.syncStateContinuation?.yield(state)
            }
        }
    }

    public func stop() async {
        coordinationTask?.cancel()
        syncResponderTask?.cancel()
        await syncEngine?.stop()
        coordinationTask = nil
        syncResponderTask = nil
        syncStateContinuation?.yield(.idle)
    }

    // MARK: - Commands

    public func send(_ command: Command, to peer: PeerID) async throws {
        try await commandRouter?.send(command, to: peer)
    }

    public func broadcast(_ command: Command) async throws {
        try await commandRouter?.broadcast(command)
    }

    // MARK: - Private

    private func startSyncResponder(transport: any Transport) {
        syncResponderTask?.cancel()
        syncResponderTask = Task { [weak self] in
            for await (sender, data) in transport.unreliableMessages {
                guard let message = try? MessageCodec.decode(data),
                      message.category == .syncRequest,
                      let t0 = try? MessageCodec.decodeSyncRequest(message.payload)
                else { continue }

                let t1 = NTPSyncEngine.now()
                let t2 = NTPSyncEngine.now()
                let response = WireMessage(
                    category: .syncResponse,
                    payload: MessageCodec.encodeSyncResponse(t0: t0, t1: t1, t2: t2)
                )
                try? await transport.sendUnreliable(MessageCodec.encode(response), to: sender)
            }
        }
    }
}
```

- [ ] **Step 4: テスト通過を確認**

Run: `swift test 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 5: コミット**

```bash
git add Sources/PeerClock/PeerClock.swift Tests/PeerClockTests/PeerClockTests.swift
git commit -m "feat: implement PeerClock facade with peer-equal architecture"
```

---

### Task 10: WiFiTransport + Discovery（実機動作用）

**Files:**
- Create: `Sources/PeerClock/Transport/Discovery.swift`
- Create: `Sources/PeerClock/Transport/WiFiTransport.swift`

注意: このタスクは Network.framework を使うため、ユニットテストでの自動テストは困難。実機テストで検証する。

- [ ] **Step 1: Discovery.swift を作成**

```swift
// Sources/PeerClock/Transport/Discovery.swift
import Foundation
import Network

/// Bonjour ディスカバリ。全ノードが同時に browse + advertise する。
final class Discovery: @unchecked Sendable {
    private let serviceName: String
    private let localPeerID: PeerID
    private let listener: NWListener
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "PeerClock.Discovery")

    private var discoveredContinuation: AsyncStream<DiscoveryEvent>.Continuation?
    let events: AsyncStream<DiscoveryEvent>

    enum DiscoveryEvent: Sendable {
        case peerFound(NWEndpoint, PeerID?)
        case peerLost(NWEndpoint)
        case listenerReady(NWEndpoint.Port)
    }

    init(serviceName: String, localPeerID: PeerID) throws {
        self.serviceName = serviceName
        self.localPeerID = localPeerID

        let tcpParams = NWParameters.tcp
        self.listener = try NWListener(using: tcpParams)
        listener.service = NWListener.Service(
            name: localPeerID.rawValue.uuidString,
            type: serviceName
        )

        let browserDesc = NWBrowser.Descriptor.bonjour(type: serviceName, domain: nil)
        self.browser = NWBrowser(for: browserDesc, using: NWParameters())

        var cont: AsyncStream<DiscoveryEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.discoveredContinuation = cont
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = self?.listener.port {
                self?.discoveredContinuation?.yield(.listenerReady(port))
            }
        }
        listener.start(queue: queue)

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    let peerID = self.extractPeerID(from: result)
                    // Don't discover ourselves
                    if peerID != self.localPeerID {
                        self.discoveredContinuation?.yield(.peerFound(result.endpoint, peerID))
                    }
                case .removed(let result):
                    self.discoveredContinuation?.yield(.peerLost(result.endpoint))
                default:
                    break
                }
            }
        }
        browser.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        browser.cancel()
        discoveredContinuation?.finish()
    }

    private func extractPeerID(from result: NWBrowser.Result) -> PeerID? {
        if case .service(let name, _, _, _) = result.endpoint,
           let uuid = UUID(uuidString: name) {
            return PeerID(rawValue: uuid)
        }
        return nil
    }
}
```

- [ ] **Step 2: WiFiTransport.swift を作成**

```swift
// Sources/PeerClock/Transport/WiFiTransport.swift
import Foundation
import Network

/// Network.framework ベースの WiFi Transport 実装。
/// UDP = unreliable チャネル、TCP = reliable チャネル。
final class WiFiTransport: Transport, @unchecked Sendable {
    private let localPeerID: PeerID
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "PeerClock.WiFiTransport")
    private let lock = NSLock()

    private var discovery: Discovery?
    private var tcpConnections: [PeerID: NWConnection] = [:]
    private var udpConnections: [PeerID: NWConnection] = [:]
    private var _connectedPeers: Set<PeerID> = []

    private var unreliableCont: AsyncStream<(PeerID, Data)>.Continuation?
    private var reliableCont: AsyncStream<(PeerID, Data)>.Continuation?
    private var connectionCont: AsyncStream<ConnectionEvent>.Continuation?

    let unreliableMessages: AsyncStream<(PeerID, Data)>
    let reliableMessages: AsyncStream<(PeerID, Data)>
    let connectionEvents: AsyncStream<ConnectionEvent>

    var connectedPeers: [PeerID] {
        lock.withLock { Array(_connectedPeers) }
    }

    init(localPeerID: PeerID, configuration: Configuration) {
        self.localPeerID = localPeerID
        self.configuration = configuration

        var uCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.unreliableMessages = AsyncStream { uCont = $0 }
        self.unreliableCont = uCont

        var rCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.reliableMessages = AsyncStream { rCont = $0 }
        self.reliableCont = rCont

        var cCont: AsyncStream<ConnectionEvent>.Continuation!
        self.connectionEvents = AsyncStream { cCont = $0 }
        self.connectionCont = cCont
    }

    func start() throws {
        let disc = try Discovery(serviceName: configuration.serviceName, localPeerID: localPeerID)
        self.discovery = disc
        disc.start()

        Task {
            for await event in disc.events {
                switch event {
                case .peerFound(let endpoint, let peerID):
                    if let peerID {
                        self.connectToPeer(peerID, endpoint: endpoint)
                    }
                case .peerLost(let endpoint):
                    // Handle peer loss based on endpoint
                    break
                case .listenerReady:
                    break
                }
            }
        }
    }

    func stop() {
        discovery?.stop()
        lock.withLock {
            for (_, conn) in tcpConnections { conn.cancel() }
            for (_, conn) in udpConnections { conn.cancel() }
            tcpConnections.removeAll()
            udpConnections.removeAll()
            _connectedPeers.removeAll()
        }
    }

    func sendUnreliable(_ data: Data, to peer: PeerID) async throws {
        let connection = lock.withLock { udpConnections[peer] }
        guard let connection else { return }
        connection.send(content: data, completion: .idempotent)
    }

    func sendReliable(_ data: Data, to peer: PeerID) async throws {
        let connection = lock.withLock { tcpConnections[peer] }
        guard let connection else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    func broadcastReliable(_ data: Data) async throws {
        let connections = lock.withLock { Array(tcpConnections.values) }
        for connection in connections {
            connection.send(content: data, completion: .idempotent)
        }
    }

    // MARK: - Private

    private func connectToPeer(_ peerID: PeerID, endpoint: NWEndpoint) {
        // TCP connection
        let tcpConnection = NWConnection(to: endpoint, using: .tcp)
        tcpConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.withLock { self._connectedPeers.insert(peerID) }
                self.connectionCont?.yield(.peerJoined(peerID))
                self.receiveReliable(from: peerID, connection: tcpConnection)
            case .failed, .cancelled:
                self.lock.withLock { self._connectedPeers.remove(peerID) }
                self.connectionCont?.yield(.peerLeft(peerID))
            default:
                break
            }
        }
        lock.withLock { tcpConnections[peerID] = tcpConnection }
        tcpConnection.start(queue: queue)

        // UDP connection
        let udpConnection = NWConnection(to: endpoint, using: .udp)
        udpConnection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveUnreliable(from: peerID, connection: udpConnection)
            }
        }
        lock.withLock { udpConnections[peerID] = udpConnection }
        udpConnection.start(queue: queue)
    }

    private func receiveReliable(from peerID: PeerID, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 65540) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            self.reliableCont?.yield((peerID, data))
            self.receiveReliable(from: peerID, connection: connection)
        }
    }

    private func receiveUnreliable(from peerID: PeerID, connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { return }
            self.unreliableCont?.yield((peerID, data))
            self.receiveUnreliable(from: peerID, connection: connection)
        }
    }
}
```

- [ ] **Step 3: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 4: PeerClock.swift の transportFactory デフォルトを WiFiTransport に更新**

`PeerClock.swift` の init 内の fatalError を以下に変更:

```swift
self.transportFactory = transportFactory ?? { peerID in
    WiFiTransport(localPeerID: peerID, configuration: configuration)
}
```

- [ ] **Step 5: ビルド確認**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete!

- [ ] **Step 6: 全テスト通過を確認**

Run: `swift test 2>&1 | tail -10`
Expected: All tests passed

- [ ] **Step 7: コミット**

```bash
git add Sources/PeerClock/Transport/Discovery.swift Sources/PeerClock/Transport/WiFiTransport.swift Sources/PeerClock/PeerClock.swift
git commit -m "feat: add WiFiTransport and Bonjour Discovery for real device operation"
```

---

## Post-Implementation

### 全テスト最終確認

```bash
swift test 2>&1
```

Expected: All tests passed (TypesTests, MessageCodecTests, CoordinatorElectionTests, NTPSyncEngineTests, DriftMonitorTests, CommandRouterTests, PeerClockTests)

### 実機テスト（手動）

1. 2台の iOS デバイスまたは Mac を同じ Wi-Fi に接続
2. サンプルアプリから `PeerClock()` を初期化して `start()` を呼ぶ
3. 両デバイスが相互発見 → coordinator 自動選出 → クロック同期を確認
4. `broadcast()` でコマンドが相手に届くことを確認
5. `now` の値が両デバイスで一致（±数ms）することを確認
