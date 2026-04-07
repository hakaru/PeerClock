# Phase 3c: Failover Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock に `FailoverTransport` ラッパを追加し、起動時 WiFi → MC の自動フォールバックを有効にする。Runtime 切替や品質監視は含まない。

**Architecture:** `FailoverTransport: Transport` が `(label, factory)` の配列を受け取り、start() 時に順番に試す。成功した最初の Transport を active に保持し、active の `peers` / `incomingMessages` を自身の AsyncStream に forward する。state machine (`.idle/.starting/.running/.stopping`) で start/stop race を直列化。PeerClock facade に `activeTransportLabel: String?` を生やして UI から可視化。

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, Foundation

**Spec reference:** `docs/superpowers/specs/2026-04-07-peerclock-v2-design.md` (Phase 3c 節)

---

## File Structure

**Create:**
- `Sources/PeerClock/Transport/FailoverTransport.swift` — ラッパ本体
- `Tests/PeerClockTests/ThrowingMockTransport.swift` — ユニットテスト用の失敗 Transport
- `Tests/PeerClockTests/FailoverTransportTests.swift` — ラッパのユニットテスト

**Modify:**
- `Sources/PeerClock/PeerClock.swift` — `activeTransportLabel` computed プロパティ追加
- `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift` — Transport モードに Auto を追加
- `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift` — Picker 3 択 + active label 表示

---

## Task 1: FailoverTransport core

**Files:**
- Create: `Sources/PeerClock/Transport/FailoverTransport.swift`

- [ ] **Step 1: Create FailoverTransport.swift**

```swift
// Sources/PeerClock/Transport/FailoverTransport.swift
import Foundation
import os

/// A Transport wrapper that tries each option in order at start() time and
/// keeps the first one that does not throw.
///
/// Design:
/// - 1 度に 1 Transport のみ動作 (runtime 切替なし)
/// - start() が throw したインスタンスは明示的に stop() してクリーンアップ
/// - active の peers / incomingMessages は専用 Task で forward
/// - start/stop は NSLock ベースの state machine で直列化
public final class FailoverTransport: Transport, @unchecked Sendable {

    // MARK: - Types

    public struct Option: Sendable {
        public let label: String
        public let factory: @Sendable () -> any Transport
        public init(label: String, factory: @escaping @Sendable () -> any Transport) {
            self.label = label
            self.factory = factory
        }
    }

    private enum State {
        case idle
        case starting
        case running
        case stopping
    }

    // MARK: - Public streams (Transport protocol)

    public let peers: AsyncStream<Set<PeerID>>
    public let incomingMessages: AsyncStream<(PeerID, Data)>

    // MARK: - Private

    private let options: [Option]
    private let logger: Logger
    private let lock = NSLock()

    private var state: State = .idle
    private var active: (label: String, transport: any Transport)?
    private var peersForwardTask: Task<Void, Never>?
    private var incomingForwardTask: Task<Void, Never>?

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingContinuation: AsyncStream<(PeerID, Data)>.Continuation

    // MARK: - Init

    public init(options: [Option]) {
        self.options = options
        self.logger = Logger(subsystem: "net.hakaru.PeerClock", category: "FailoverTransport")

        var peersCont: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont

        var incomingCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingCont = $0 }
        self.incomingContinuation = incomingCont
    }

    // MARK: - Public

    /// 現在 active な Transport のラベル。未起動時は nil。NSLock で保護。
    public var activeLabel: String? {
        lock.withLock { active?.label }
    }

    // MARK: - Transport protocol

    public func start() async throws {
        // state transition: idle → starting (reject if not idle)
        try lock.withLock {
            switch state {
            case .idle:
                state = .starting
            case .starting, .running:
                // 二重 start は no-op (既に実行中)
                throw FailoverTransportError.alreadyStarted
            case .stopping:
                throw FailoverTransportError.alreadyStarted
            }
        }

        guard !options.isEmpty else {
            lock.withLock { state = .idle }
            throw FailoverTransportError.noOptionsAvailable
        }

        var errors: [Error] = []
        for option in options {
            let transport = option.factory()
            do {
                try await transport.start()
            } catch {
                // 部分初期化のクリーンアップ
                await transport.stop()
                logger.warning("FailoverTransport option \(option.label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                errors.append(error)
                continue
            }

            // 成功: active にセットして forward タスク起動
            lock.withLock {
                self.active = (option.label, transport)
                self.state = .running
            }
            startForwarding(from: transport)
            logger.info("FailoverTransport active: \(option.label, privacy: .public)")
            return
        }

        // 全 option 失敗
        lock.withLock { state = .idle }
        throw FailoverTransportError.allOptionsFailed(underlying: errors)
    }

    public func stop() async {
        // state transition to stopping (idempotent)
        let (wasRunning, peersTask, incomingTask, active) = lock.withLock {
            () -> (Bool, Task<Void, Never>?, Task<Void, Never>?, (label: String, transport: any Transport)?) in
            switch state {
            case .idle, .stopping:
                return (false, nil, nil, nil)
            case .starting:
                // starting 中の stop: starting 完了を待たず、active が
                // まだ nil ならそのまま idle に戻すだけ。ただし現実的には
                // start ループ中は lock を放していないので、ここに来ることは
                // 稀 (NSLock は reentrant ではないため、start の lock.withLock
                // 外で option.factory().start() を呼ぶ間だけレース可能)。
                state = .stopping
                let pt = peersForwardTask
                let it = incomingForwardTask
                let act = self.active
                self.peersForwardTask = nil
                self.incomingForwardTask = nil
                self.active = nil
                return (true, pt, it, act)
            case .running:
                state = .stopping
                let pt = peersForwardTask
                let it = incomingForwardTask
                let act = self.active
                self.peersForwardTask = nil
                self.incomingForwardTask = nil
                self.active = nil
                return (true, pt, it, act)
            }
        }

        guard wasRunning else { return }

        // 1. Active Transport を stop → upstream の stream が finish
        if let active {
            await active.transport.stop()
        }

        // 2. forward task の自然終了を待つ (upstream が finish したので
        //    for-await は抜ける)。保険として cancel() も呼ぶ。
        peersTask?.cancel()
        incomingTask?.cancel()
        await peersTask?.value
        await incomingTask?.value

        // 3. 自身の continuation を finish
        peersContinuation.finish()
        incomingContinuation.finish()

        // 4. state を idle に
        lock.withLock { state = .idle }
        logger.info("FailoverTransport stopped")
    }

    public func send(_ data: Data, to peer: PeerID) async throws {
        let transport = lock.withLock { active?.transport }
        guard let transport else {
            throw FailoverTransportError.notStarted
        }
        try await transport.send(data, to: peer)
    }

    public func broadcast(_ data: Data) async throws {
        let transport = lock.withLock { active?.transport }
        guard let transport else {
            throw FailoverTransportError.notStarted
        }
        try await transport.broadcast(data)
    }

    public func broadcastUnreliable(_ data: Data) async throws {
        let transport = lock.withLock { active?.transport }
        guard let transport else {
            throw FailoverTransportError.notStarted
        }
        try await transport.broadcastUnreliable(data)
    }

    // MARK: - Forwarding

    private func startForwarding(from transport: any Transport) {
        let peersCont = peersContinuation
        let incomingCont = incomingContinuation

        let peersTask = Task {
            for await snapshot in transport.peers {
                if Task.isCancelled { break }
                peersCont.yield(snapshot)
            }
        }
        let incomingTask = Task {
            for await message in transport.incomingMessages {
                if Task.isCancelled { break }
                incomingCont.yield(message)
            }
        }
        lock.withLock {
            self.peersForwardTask = peersTask
            self.incomingForwardTask = incomingTask
        }
    }
}

// MARK: - Errors

public enum FailoverTransportError: Error, Sendable {
    /// options 配列が空のまま start() が呼ばれた。
    case noOptionsAvailable
    /// 全 option の factory().start() が throw した。underlying は options 順。
    case allOptionsFailed(underlying: [Error])
    /// start() 前の送信。
    case notStarted
    /// 既に starting / running 状態での二重 start。
    case alreadyStarted
}
```

- [ ] **Step 2: Build**

```bash
cd /Volumes/Dev/DEVELOP/PeerClock
swift build 2>&1 | tail -10
swift test 2>&1 | tail -5
```

Expected: Build complete, 87 tests passing (no regression — FailoverTransport has no tests yet).

- [ ] **Step 3: Commit**

```bash
git add Sources/PeerClock/Transport/FailoverTransport.swift
git commit -m "feat(transport): FailoverTransport wrapper with state machine"
```

---

## Task 2: ThrowingMockTransport test helper

**Files:**
- Create: `Tests/PeerClockTests/ThrowingMockTransport.swift`

- [ ] **Step 1: Create ThrowingMockTransport.swift**

```swift
// Tests/PeerClockTests/ThrowingMockTransport.swift
import Foundation
@testable import PeerClock

/// A Transport whose `start()` always throws. Used by FailoverTransportTests
/// to simulate a failing option.
final class ThrowingMockTransport: Transport, @unchecked Sendable {

    struct FailureError: Error, Equatable {
        let label: String
    }

    let label: String
    let peers: AsyncStream<Set<PeerID>>
    let incomingMessages: AsyncStream<(PeerID, Data)>
    private(set) var stopWasCalled = false

    private let peersContinuation: AsyncStream<Set<PeerID>>.Continuation
    private let incomingContinuation: AsyncStream<(PeerID, Data)>.Continuation
    private let lock = NSLock()

    init(label: String) {
        self.label = label

        var peersCont: AsyncStream<Set<PeerID>>.Continuation!
        self.peers = AsyncStream { peersCont = $0 }
        self.peersContinuation = peersCont

        var incomingCont: AsyncStream<(PeerID, Data)>.Continuation!
        self.incomingMessages = AsyncStream { incomingCont = $0 }
        self.incomingContinuation = incomingCont
    }

    func start() async throws {
        throw FailureError(label: label)
    }

    func stop() async {
        lock.withLock { stopWasCalled = true }
        peersContinuation.finish()
        incomingContinuation.finish()
    }

    func send(_ data: Data, to peer: PeerID) async throws {
        throw FailureError(label: label)
    }

    func broadcast(_ data: Data) async throws {
        throw FailureError(label: label)
    }
}
```

- [ ] **Step 2: Build (no tests yet — just compile check)**

```bash
swift build 2>&1 | tail -5
```

Expected: clean build. The helper is only referenced from tests (next task).

- [ ] **Step 3: Commit**

```bash
git add Tests/PeerClockTests/ThrowingMockTransport.swift
git commit -m "test(phase-3c): ThrowingMockTransport helper"
```

---

## Task 3: FailoverTransportTests

**Files:**
- Create: `Tests/PeerClockTests/FailoverTransportTests.swift`

- [ ] **Step 1: Create FailoverTransportTests.swift**

```swift
// Tests/PeerClockTests/FailoverTransportTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("FailoverTransport")
struct FailoverTransportTests {

    @Test("Empty options throw noOptionsAvailable")
    func emptyOptionsThrow() async throws {
        let failover = FailoverTransport(options: [])
        do {
            try await failover.start()
            Issue.record("Expected throw")
        } catch FailoverTransportError.noOptionsAvailable {
            // ok
        }
    }

    @Test("All options throw → allOptionsFailed with ordered underlying")
    func allOptionsFail() async throws {
        let failover = FailoverTransport(options: [
            .init(label: "A") { ThrowingMockTransport(label: "A") },
            .init(label: "B") { ThrowingMockTransport(label: "B") },
        ])

        do {
            try await failover.start()
            Issue.record("Expected throw")
        } catch FailoverTransportError.allOptionsFailed(let underlying) {
            #expect(underlying.count == 2)
            #expect((underlying[0] as? ThrowingMockTransport.FailureError)?.label == "A")
            #expect((underlying[1] as? ThrowingMockTransport.FailureError)?.label == "B")
        }

        #expect(failover.activeLabel == nil)
    }

    @Test("First throwing option falls back to second successful option")
    func fallbackSucceeds() async throws {
        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())

        let failover = FailoverTransport(options: [
            .init(label: "Bad") { ThrowingMockTransport(label: "Bad") },
            .init(label: "Good") { MockTransport(localPeerID: localID, network: network) },
        ])

        try await failover.start()
        #expect(failover.activeLabel == "Good")

        await failover.stop()
    }

    @Test("Single successful option becomes active")
    func singleSuccess() async throws {
        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())

        let failover = FailoverTransport(options: [
            .init(label: "Only") { MockTransport(localPeerID: localID, network: network) }
        ])

        try await failover.start()
        #expect(failover.activeLabel == "Only")

        await failover.stop()
        #expect(failover.activeLabel == nil)
    }

    @Test("send throws notStarted before start")
    func sendBeforeStartThrows() async throws {
        let failover = FailoverTransport(options: [])
        do {
            try await failover.send(Data(), to: PeerID(rawValue: UUID()))
            Issue.record("Expected throw")
        } catch FailoverTransportError.notStarted {
            // ok
        }
    }

    @Test("Active transport's peers stream is forwarded")
    func peersForwarded() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())

        let failoverA = FailoverTransport(options: [
            .init(label: "A") { MockTransport(localPeerID: a, network: network) }
        ])
        let transportB = MockTransport(localPeerID: b, network: network)

        try await failoverA.start()
        try await transportB.start()

        // failoverA should see B appear via the forwarded stream.
        var it = failoverA.peers.makeAsyncIterator()
        var sawB = false
        for _ in 0..<5 {
            if let next = await it.next(), next.contains(b) {
                sawB = true
                break
            }
        }
        #expect(sawB)

        await failoverA.stop()
        await transportB.stop()
    }

    @Test("broadcast is forwarded to active transport")
    func broadcastForwarded() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())

        let failoverA = FailoverTransport(options: [
            .init(label: "A") { MockTransport(localPeerID: a, network: network) }
        ])
        let transportB = MockTransport(localPeerID: b, network: network)

        try await failoverA.start()
        try await transportB.start()

        // Wait for B to see A.
        var peersIt = transportB.peers.makeAsyncIterator()
        while let next = await peersIt.next() {
            if next.contains(a) { break }
        }

        // Broadcast from failoverA → transportB should receive.
        let payload = Data([0x42, 0x43, 0x44])
        try await failoverA.broadcast(payload)

        var incomingIt = transportB.incomingMessages.makeAsyncIterator()
        let received = await incomingIt.next()
        #expect(received?.1 == payload)

        await failoverA.stop()
        await transportB.stop()
    }

    @Test("Failing option is stopped before moving to next")
    func failedOptionIsStopped() async throws {
        // Capture the ThrowingMockTransport instance by reference.
        final class Box: @unchecked Sendable {
            var transport: ThrowingMockTransport?
        }
        let box = Box()

        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())

        let failover = FailoverTransport(options: [
            .init(label: "Bad") {
                let t = ThrowingMockTransport(label: "Bad")
                box.transport = t
                return t
            },
            .init(label: "Good") { MockTransport(localPeerID: localID, network: network) }
        ])

        try await failover.start()
        #expect(box.transport?.stopWasCalled == true)

        await failover.stop()
    }
}
```

- [ ] **Step 2: Build & test**

```bash
swift build 2>&1 | tail -5
swift test --filter FailoverTransportTests 2>&1 | tail -20
swift test 2>&1 | tail -5
```

Expected: 8 new tests pass, total 95 tests passing.

If the `peersForwarded` or `broadcastForwarded` tests flake due to timing, increase the iteration budget (5 → 10) but do not weaken the assertions.

- [ ] **Step 3: Commit**

```bash
git add Tests/PeerClockTests/FailoverTransportTests.swift
git commit -m "test(phase-3c): FailoverTransport unit tests"
```

---

## Task 4: PeerClock.activeTransportLabel

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`

- [ ] **Step 1: Read PeerClock.swift and locate the other computed properties**

Find the `coordinatorID` computed var (around line 40). We add a similar property next to it.

- [ ] **Step 2: Add activeTransportLabel**

Right after the `coordinatorID` getter, add:

```swift
    /// FailoverTransport 使用時のみ非 nil。現在 active な Transport の label を返す。
    /// 通常の Transport (WiFiTransport, MultipeerTransport など) 使用時は nil。
    public var activeTransportLabel: String? {
        let current = lock.withLock { transport }
        return (current as? FailoverTransport)?.activeLabel
    }
```

- [ ] **Step 3: Build & test**

```bash
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: 95 tests still passing.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift
git commit -m "feat(facade): expose activeTransportLabel for FailoverTransport"
```

---

## Task 5: Demo app — Auto mode + active label display

**Files:**
- Modify: `Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift`
- Modify: `Examples/PeerClockDemo/PeerClockDemo/ContentView.swift`

- [ ] **Step 1: Extend ViewModel transport mode**

Read `PeerClockViewModel.swift`. Phase 3b added `useMultipeerConnectivity: Bool`. Replace it with a 3-value enum:

```swift
    enum TransportMode: String, CaseIterable, Sendable {
        case wifi = "WiFi"
        case mc = "MC"
        case auto = "Auto"
    }

    var transportMode: TransportMode = .wifi
```

Remove the old `useMultipeerConnectivity` stored property.

Update `start()` to branch on `transportMode`:

```swift
        let clock: PeerClock
        switch transportMode {
        case .wifi:
            clock = PeerClock()
            appendLog("Using WiFiTransport (default)")
        case .mc:
            clock = PeerClock(transportFactory: { peerID in
                MultipeerTransport(localPeerID: peerID, configuration: .default)
            })
            appendLog("Using MultipeerTransport (MC)")
        case .auto:
            clock = PeerClock(transportFactory: { peerID in
                FailoverTransport(options: [
                    .init(label: "WiFi") {
                        WiFiTransport(localPeerID: peerID, configuration: .default)
                    },
                    .init(label: "MC") {
                        MultipeerTransport(localPeerID: peerID, configuration: .default)
                    }
                ])
            })
            appendLog("Using FailoverTransport (Auto)")
        }
```

Also add an observable computed property for the active label (Auto mode only):

```swift
    var activeTransportLabel: String? {
        clock?.activeTransportLabel
    }
```

(If `clock` is `private`, expose this through the existing pattern — read the file to match.)

- [ ] **Step 2: Update ContentView Picker**

Read `ContentView.swift`. Find the existing Picker (from Phase 3b):

```swift
                Picker("", selection: $viewModel.useMultipeerConnectivity) {
                    Text("WiFi").tag(false)
                    Text("MC").tag(true)
                }
```

Replace with a 3-value picker:

```swift
                Picker("", selection: $viewModel.transportMode) {
                    ForEach(PeerClockViewModel.TransportMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .disabled(!viewModel.isStopped)
```

The width grows from 140 → 200 to fit 3 segments.

- [ ] **Step 3: Add active label display**

In the Sync Status section of ContentView, below the existing sync line, add:

```swift
            if viewModel.transportMode == .auto,
               let label = viewModel.activeTransportLabel {
                Text("via \(label)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
```

Place this inside the same VStack as the Sync Status content.

- [ ] **Step 4: Xcode build**

```bash
xcodebuild -project /Volumes/Dev/DEVELOP/PeerClock/Examples/PeerClockDemo/PeerClockDemo.xcodeproj -scheme PeerClockDemo -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -10
```

Expected: `BUILD SUCCEEDED`.

If you get errors:
- `activeTransportLabel` might need `@MainActor` bridging if `clock` access from the getter is restricted — in that case, make it a `func activeTransportLabel() async -> String?` and call it from ContentView via a Task.
- `isStopped` was added by Phase 3b — it already exists.

- [ ] **Step 5: Commit**

```bash
git add Examples/PeerClockDemo/PeerClockDemo/PeerClockViewModel.swift Examples/PeerClockDemo/PeerClockDemo/ContentView.swift
git commit -m "feat(demo): add Auto transport mode with active label display"
```

---

## Task 6: Simulator smoke verification

**Files:** No code changes. Manual.

- [ ] **Step 1: Deploy to both simulators**

```bash
APP="/Users/hakaru/Library/Developer/Xcode/DerivedData/PeerClockDemo-drqkujgbdgpwfdblvgcnuecbddks/Build/Products/Debug-iphonesimulator/PeerClockDemo.app"
xcrun simctl terminate AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl terminate 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl install AF61223F-58C5-48A3-BF21-54F942BA3C32 "$APP"
xcrun simctl install 981BFB44-64A5-476D-88B2-9B34CF8D8762 "$APP"
xcrun simctl launch AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo
xcrun simctl launch 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo
```

- [ ] **Step 2: Manual checks (user performs)**

1. ✅ Both apps launch, Transport segmented control shows 3 options: WiFi / MC / Auto
2. ✅ Select `Auto` on both → Start → peers discover each other. The UI shows `via WiFi` under Sync Status (WiFi succeeded first).
3. ✅ Log shows `Using FailoverTransport (Auto)`.
4. ✅ Existing features (Schedule +3s, Broadcast Ping, heartbeat) work in Auto mode.
5. ✅ Stop and switch to WiFi mode → Start → normal WiFi operation (no via label).
6. ✅ Stop and switch to MC mode → Start → app does not crash (MC discovery may not work between sims per Phase 3b limitation).
7. ✅ While running, the Transport picker is disabled.

- [ ] **Step 3: Tag completion**

```bash
git tag -a phase-3c-complete -m "Phase 3c: FailoverTransport complete"
```

(don't push)

---

## Self-Review Checklist

- [x] Spec coverage:
  - FailoverTransport ラッパ + state machine → Task 1
  - ThrowingMockTransport helper → Task 2
  - ユニットテスト (8 cases: empty, all-fail, fallback, single, notStarted, peers forwarding, broadcast forwarding, failed-stopped) → Task 3
  - PeerClock.activeTransportLabel → Task 4
  - Demo app 3 モード + active ラベル表示 → Task 5
  - Smoke verification → Task 6
- [x] Placeholder scan: 全ステップに actual code あり
- [x] Type consistency: `FailoverTransport`, `FailoverTransportError`, `Option`, `TransportMode`, `activeTransportLabel`, `activeLabel`, `ThrowingMockTransport.FailureError` が全タスクで同名
- [x] TDD: Task 2-3 はテストヘルパとテストの順。Task 1 の FailoverTransport は Task 3 で検証
- [x] Frequent commits: 6 tasks × 1 commit each

## Known Risks

1. **NSLock の再入性なし (Task 1)**: `start()` 内の `lock.withLock { state = .starting }` の外側で `option.factory().start()` を呼ぶので、その間は lock を保持していない。この隙に `stop()` が呼ばれる可能性がある。spec の state machine ではそのケースで `state = .stopping` にした後、start() ループが続行して factory.start() が成功した時に active をセットしようとする問題がある。実装では factory 成功後の `lock.withLock { active = ..., state = .running }` の前に state が `.stopping` に変わっていないか確認し、そうなっていれば成功した transport を stop して return する防御ロジックを入れる方が安全。**Task 1 実装者はこのガードを追加すること**。

2. **forward task の cancel 待ち (Task 1)**: `peersTask?.value`  / `incomingTask?.value` を await するので、もし upstream が finish しないケースがあると stop() が永遠にブロックされる。`MockTransport` / `WiFiTransport` / `MultipeerTransport` はすべて `stop()` で continuation を finish するので安全だが、第三者の Transport 実装では保証されない。spec は「既存の 3 実装は finish するので OK」という前提。実装コメントにこの前提を明記すること。

3. **Demo app の activeTransportLabel reactivity (Task 5)**: ViewModel の `var activeTransportLabel` は computed property で `clock?.activeTransportLabel` を読む。SwiftUI の @Observable 再描画がこの computed を再評価するかは、`clock` の変化を ViewModel が observe しているかに依存する。Start 時に設定されるので、`runState` の変化をトリガに再描画される想定。反応が遅い場合は明示的に `didSet` や Task で observable を更新する。

4. **Task 5 `clock` への ViewModel アクセス**: Phase 2a 以降 `clock` は private。ViewModel が自分で computed でラップする形は OK だが、Actor isolation や MainActor bridging で問題が出るなら `@MainActor` を明示する必要あり。Xcode エラーが出たら Task 5 Step 4 のメモに従って対応。
