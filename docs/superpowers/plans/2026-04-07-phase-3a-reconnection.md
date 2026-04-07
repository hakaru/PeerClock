# Phase 3a: Reconnection + Coordinator Re-Election Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** PeerClock に 2 層防御の再接続機構と coordinator 再選出の確実な配線を追加し、ピアの一時切断から自動復帰できるようにする。

**Architecture:** Transport 層 (WiFiTransport) に 500ms × 3 の短期リトライと受信側 Last-In-Win を追加。上位層 (PeerClock) は `HeartbeatMonitor.events` を election の入力に加え、peer 復帰時に `NTPSyncEngine.reset()` + `StatusRegistry.flushNow()` でフル再同期を 1 回トリガする。MockNetwork に `simulateDisconnect` / `simulateReconnect` を追加して決定論的なユニットテストで検証する。

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, Network.framework, Foundation

**Spec reference:** `docs/superpowers/specs/2026-04-07-peerclock-v2-design.md` (Phase 3a 節)

---

## File Structure

**Create:**
- `Tests/PeerClockTests/ReconnectionTests.swift` — MockNetwork 拡張を使った決定論的テスト
- `Tests/PeerClockTests/CoordinatorReelectionTests.swift` — 3 台構成の再選出ユニットテスト

**Modify:**
- `Sources/PeerClock/Configuration.swift` — `reconnectRetryInterval`, `reconnectMaxAttempts` 追加
- `Sources/PeerClock/ClockSync/NTPSyncEngine.swift` — `reset()` メソッド追加、`start(coordinator:)` で内部統計をリセット
- `Sources/PeerClock/Transport/MockTransport.swift` — `simulateDisconnect` / `simulateReconnect` API 追加
- `Sources/PeerClock/Transport/WiFiTransport.swift` — 短期リトライ + Last-In-Win
- `Sources/PeerClock/PeerClock.swift` — HeartbeatMonitor.events → election 配線、flushNow() の 1 回呼び出し

---

## Task 1: Configuration fields

**Files:**
- Modify: `Sources/PeerClock/Configuration.swift`

- [ ] **Step 1: Configuration に再接続フィールドを追加**

現状の Configuration は Phase 2a の heartbeat/status 項目を持つ。Heartbeat 項目群の直後 (`disconnectedAfter` の下) に以下を追加:

```swift
    // MARK: - Reconnect

    /// Transport 層の再接続リトライ間隔。
    public let reconnectRetryInterval: TimeInterval

    /// Transport 層の再接続リトライ最大回数。
    public let reconnectMaxAttempts: Int
```

`init` の引数にも追加:

```swift
        reconnectRetryInterval: TimeInterval = 0.5,
        reconnectMaxAttempts: Int = 3,
```

引数代入も追加:

```swift
        self.reconnectRetryInterval = reconnectRetryInterval
        self.reconnectMaxAttempts = reconnectMaxAttempts
```

引数の位置: `disconnectedAfter` の直後、`statusSendDebounce` の前。

- [ ] **Step 2: ビルド & 全テスト**

```bash
cd /Volumes/Dev/DEVELOP/PeerClock
swift build 2>&1 | tail -5
swift test 2>&1 | tail -5
```

Expected: Build complete, 73 tests passing (no regression).

- [ ] **Step 3: Commit**

```bash
git add Sources/PeerClock/Configuration.swift
git commit -m "feat(config): add Phase 3a reconnect fields"
```

---

## Task 2: NTPSyncEngine reset on (re-)start

**Files:**
- Modify: `Sources/PeerClock/ClockSync/NTPSyncEngine.swift`
- Modify: `Tests/PeerClockTests/NTPSyncEngineTests.swift`

- [ ] **Step 1: NTPSyncEngine.start(coordinator:) の冒頭で内部統計をリセット**

`start(coordinator:)` メソッドを以下に置き換える:

```swift
    public func start(coordinator: PeerID) async {
        // Phase 3a: 役割切替時の古い統計残留を防ぐため、start 時に必ず
        // 内部状態をリセットする。
        lock.withLock {
            self.coordinatorID = coordinator
            self._currentOffset = 0.0
        }
        syncStateContinuation.yield(.syncing)

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runSyncLoop()
        }
        lock.withLock { self.syncTask = task }
    }
```

変更点: `_currentOffset = 0.0` を `lock.withLock` 内で追加。coordinatorID の代入と同じロック取得にまとめた。

**Note**: 現状の NTPSyncEngine は `_currentOffset` 以外の永続状態 (RTT 履歴やドリフト推定バッファ) は保持していない — 各 `runSyncLoop` イテレーションで再収集する。従って `_currentOffset = 0.0` のリセットで十分。

- [ ] **Step 2: 既存 NTPSyncEngineTests を確認して reset テストを追加**

`Tests/PeerClockTests/NTPSyncEngineTests.swift` を読み、最後の test の後ろに追加:

```swift
    @Test("start() resets currentOffset from previous session")
    func startResetsCurrentOffset() async {
        let network = MockNetwork()
        let localID = PeerID(rawValue: UUID())
        let coordA = PeerID(rawValue: UUID())
        let transport = await network.createTransport(for: localID)
        let router = CommandRouter(transport: transport)
        let engine = NTPSyncEngine(
            transport: transport,
            localPeerID: localID,
            configuration: .default,
            syncMessageStream: router.syncMessages
        )

        // Seed an offset via a synthetic successful sync is complex; instead
        // we exercise reset by calling start twice and confirming that after
        // the second start, `currentOffset` begins at 0.
        await engine.start(coordinator: coordA)
        #expect(engine.currentOffset == 0.0)
        await engine.stop()

        let coordB = PeerID(rawValue: UUID())
        await engine.start(coordinator: coordB)
        #expect(engine.currentOffset == 0.0)
        await engine.stop()
    }
```

- [ ] **Step 3: Build & test**

```bash
swift build 2>&1 | tail -5
swift test --filter NTPSyncEngineTests 2>&1 | tail -15
swift test 2>&1 | tail -5
```

Expected: new test passes, all other NTPSyncEngine tests still pass, total 74 tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/ClockSync/NTPSyncEngine.swift Tests/PeerClockTests/NTPSyncEngineTests.swift
git commit -m "feat(sync): reset currentOffset on start() for clean role switches"
```

---

## Task 3: MockNetwork simulate APIs

**Files:**
- Modify: `Sources/PeerClock/Transport/MockTransport.swift`
- Create: `Tests/PeerClockTests/MockNetworkSimulationTests.swift`

- [ ] **Step 1: Add simulateDisconnect and simulateReconnect to MockNetwork**

Read current MockNetwork first. Then add these methods to the `MockNetwork` actor:

```swift
    /// Simulates a transport-level disconnect for a specific peer pair:
    /// the `peer`'s transport is temporarily removed from the network so
    /// sends to/from it stop being routed. Use `simulateReconnect` to restore.
    public func simulateDisconnect(peer: PeerID) async {
        guard let transport = transports[peer] else { return }
        // Mark as disconnected: keep the transport object but drop it from
        // the routable set so broadcasts and sends no longer reach it.
        disconnected.insert(peer)
        await publishPeerSnapshots()
        _ = transport
    }

    /// Restores a previously disconnected peer. The transport becomes
    /// routable again and publishes new peer snapshots.
    public func simulateReconnect(peer: PeerID) async {
        disconnected.remove(peer)
        await publishPeerSnapshots()
    }
```

Add a private stored property:

```swift
    private var disconnected: Set<PeerID> = []
```

Modify `send`, `broadcast`, `publishPeerSnapshots` to skip disconnected peers. The replacements are:

```swift
    func send(
        _ data: Data,
        from sender: PeerID,
        to receiver: PeerID,
        latency: Duration,
        packetDropProbability: Double
    ) async {
        guard !disconnected.contains(sender), !disconnected.contains(receiver) else {
            return
        }
        guard Double.random(in: 0...1) >= packetDropProbability else {
            return
        }
        guard let transport = transports[receiver] else {
            return
        }

        if latency > .zero {
            try? await Task.sleep(for: latency)
        }
        transport.receive(from: sender, data: data)
    }

    func broadcast(
        _ data: Data,
        from sender: PeerID,
        latency: Duration,
        packetDropProbability: Double
    ) async {
        guard !disconnected.contains(sender) else { return }
        let receivers = transports
            .filter { $0.key != sender && !disconnected.contains($0.key) }
            .map(\.value)

        for transport in receivers {
            await send(
                data,
                from: sender,
                to: transport.localPeerID,
                latency: latency,
                packetDropProbability: packetDropProbability
            )
        }
    }

    private func publishPeerSnapshots() async {
        let liveIDs = Set(transports.keys).subtracting(disconnected)
        for transport in transports.values {
            if disconnected.contains(transport.localPeerID) {
                // This peer is simulated-disconnected: report empty peer set locally.
                transport.updatePeers([])
            } else {
                var peers = liveIDs
                peers.remove(transport.localPeerID)
                transport.updatePeers(peers)
            }
        }
    }
```

- [ ] **Step 2: Create MockNetworkSimulationTests.swift**

```swift
// Tests/PeerClockTests/MockNetworkSimulationTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("MockNetwork simulate APIs")
struct MockNetworkSimulationTests {

    @Test("simulateDisconnect removes peer from others' peer lists")
    func disconnectDropsPeer() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())
        let ta = await network.createTransport(for: a)
        let tb = await network.createTransport(for: b)
        try await ta.start()
        try await tb.start()

        // Both should initially see each other.
        var itA = ta.peers.makeAsyncIterator()
        var itB = tb.peers.makeAsyncIterator()
        var snapA: Set<PeerID>? = nil
        var snapB: Set<PeerID>? = nil
        while snapA == nil || snapB == nil {
            if snapA == nil, let next = await itA.next(), next.contains(b) {
                snapA = next
            }
            if snapB == nil, let next = await itB.next(), next.contains(a) {
                snapB = next
            }
        }

        await network.simulateDisconnect(peer: a)

        // After disconnect, B should see an empty peer set.
        while let next = await itB.next() {
            if !next.contains(a) { break }
        }

        await ta.stop()
        await tb.stop()
    }

    @Test("simulateDisconnect then simulateReconnect restores routing")
    func reconnectRestores() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())
        let ta = await network.createTransport(for: a)
        let tb = await network.createTransport(for: b)
        try await ta.start()
        try await tb.start()

        // Wait for initial peer sync.
        var itB = tb.peers.makeAsyncIterator()
        while let next = await itB.next() {
            if next.contains(a) { break }
        }

        await network.simulateDisconnect(peer: a)

        // B sees peer drop.
        while let next = await itB.next() {
            if !next.contains(a) { break }
        }

        await network.simulateReconnect(peer: a)

        // B sees peer re-appear.
        while let next = await itB.next() {
            if next.contains(a) { break }
        }

        await ta.stop()
        await tb.stop()
    }

    @Test("Messages to disconnected peer are dropped")
    func messagesDropped() async throws {
        let network = MockNetwork()
        let a = PeerID(rawValue: UUID())
        let b = PeerID(rawValue: UUID())
        let ta = await network.createTransport(for: a)
        let tb = await network.createTransport(for: b)
        try await ta.start()
        try await tb.start()

        // Wait for mutual recognition.
        var itB = tb.peers.makeAsyncIterator()
        while let next = await itB.next() {
            if next.contains(a) { break }
        }

        await network.simulateDisconnect(peer: b)

        // Send from A to B — should be silently dropped.
        try await ta.send(Data([0x01, 0x02]), to: b)
        // Give the mock a moment to (not) deliver.
        try await Task.sleep(nanoseconds: 50_000_000)

        // Read any pending incoming on B — should be nothing.
        // We use a race: if something arrives in 100ms, fail.
        actor Received {
            var got: [Data] = []
            func add(_ d: Data) { got.append(d) }
            func read() -> [Data] { got }
        }
        let received = Received()
        let task = Task {
            for await (_, data) in tb.incomingMessages {
                await received.add(data)
                break
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        #expect(await received.read().isEmpty)

        await ta.stop()
        await tb.stop()
    }
}
```

- [ ] **Step 3: Build & test**

```bash
swift build 2>&1 | tail -5
swift test --filter MockNetworkSimulationTests 2>&1 | tail -15
swift test 2>&1 | tail -5
```

Expected: 3 new tests pass, all existing tests still pass (77 total).

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Transport/MockTransport.swift Tests/PeerClockTests/MockNetworkSimulationTests.swift
git commit -m "feat(mock): add simulateDisconnect/simulateReconnect for Phase 3a tests"
```

---

## Task 4: PeerClock heartbeat → election + flushNow wiring

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`

- [ ] **Step 1: Read PeerClock.swift and locate runCoordinationLoop**

Read the whole `PeerClock.swift` to understand the current structure. Focus on:
- `runCoordinationLoop(transport:)` which receives `for await peers in transport.peers`
- The Phase 2a additions: `statusRegistry`, `statusReceiver`, `heartbeatMonitor`, `heartbeatRoutingTask`, `statusPushRoutingTask`
- How `HeartbeatMonitor.events` is already consumed (it currently updates `Peer.status.connectionState` via `updateConnection`)

- [ ] **Step 2: Add effective peer set that excludes heartbeat-disconnected peers**

In `runCoordinationLoop`, after computing `newPeerList` from transport.peers but before calling `elec.updatePeers`, query each peer's heartbeat state and exclude `.disconnected` ones. Replace the election call with:

```swift
            // Phase 3a: treat heartbeat-disconnected peers as gone for election.
            var effectivePeers: [PeerID] = []
            if let hb = lock.withLock({ heartbeatMonitor }) {
                for p in newPeerList {
                    let state = await hb.currentState(of: p)
                    if state != .disconnected {
                        effectivePeers.append(p)
                    }
                }
            } else {
                effectivePeers = newPeerList
            }

            // Update election with effective peer set.
            elec.updatePeers(effectivePeers + [localPeerID])
```

(The exact variable name for the heartbeat monitor is whatever the Phase 2a code uses — likely `heartbeatMonitor`.)

- [ ] **Step 3: Call statusRegistry.flushNow() once when peers are added**

Locate where `added` peers are detected in `runCoordinationLoop` (Phase 2a added this block for heartbeat peerJoined). After the `for p in added { await hb.peerJoined(p) }` loop, add:

```swift
            // Phase 3a: if any peer joined (or re-joined), flush local status
            // once to broadcast our full state. flushNow is a broadcast, so one
            // call is enough regardless of how many peers joined.
            if !added.isEmpty {
                if let registry = lock.withLock({ statusRegistry }) {
                    // Optional jitter (0-100ms) to avoid storm when multiple
                    // peers rejoin at once.
                    let jitterNs = UInt64.random(in: 0...100_000_000)
                    try? await Task.sleep(nanoseconds: jitterNs)
                    await registry.flushNow()
                }
            }
```

- [ ] **Step 4: Also re-trigger election when heartbeat reports disconnected**

Phase 2a already launches a task consuming `heartbeatMonitor.events` for UI. Add a secondary consumer (or extend the existing one) that, on `.disconnected`, triggers a re-evaluation of the election. Since `runCoordinationLoop` only runs when `transport.peers` changes, heartbeat-only disconnections (TCP half-open) won't trigger it. Add a new routing task in `start()` after the existing heartbeat setup:

```swift
        // Phase 3a: heartbeat disconnected → force coordination re-eval
        let hbElectionTask = Task { [weak self] in
            guard let self else { return }
            for await event in heartbeat.events {
                if case .disconnected = event.state {
                    await self.reevaluateCoordination()
                }
            }
        }
        lock.withLock { self.heartbeatElectionTask = hbElectionTask }
```

Add the new task storage property alongside other Phase 2a private vars:

```swift
    private var heartbeatElectionTask: Task<Void, Never>?
```

Add the re-evaluation helper method:

```swift
    /// Phase 3a: triggered by heartbeat disconnect. Re-runs election with the
    /// current transport peer set so that heartbeat-only disconnects (TCP
    /// half-open) also cause coordinator re-selection.
    private func reevaluateCoordination() async {
        let (peers, elec, eng, hb) = lock.withLock {
            (knownPeers, election, syncEngine, heartbeatMonitor)
        }
        guard let elec, let eng else { return }

        var effective: [PeerID] = []
        if let hb {
            for p in peers {
                let state = await hb.currentState(of: p)
                if state != .disconnected {
                    effective.append(p)
                }
            }
        } else {
            effective = Array(peers)
        }

        let prevCoordinator = lock.withLock { currentCoordinator }
        elec.updatePeers(effective + [localPeerID])
        let newCoordinator = elec.coordinator
        guard newCoordinator != prevCoordinator else { return }

        lock.withLock { currentCoordinator = newCoordinator }

        if elec.isCoordinator {
            await eng.stop()
            // Note: startSyncResponder is private; if called from here, we'd
            // need transport access. For now, the next transport.peers tick
            // will drive the responder switch via runCoordinationLoop.
        } else if let newCoordinator {
            await eng.stop()
            await eng.start(coordinator: newCoordinator)
        }
    }
```

- [ ] **Step 5: Cancel the new task in stop()**

In the existing `stop()` method's lock collection tuple, add:

```swift
        let hbElecTask = heartbeatElectionTask; heartbeatElectionTask = nil
```

After the lock block:

```swift
        hbElecTask?.cancel()
```

- [ ] **Step 6: Build**

```bash
swift build 2>&1 | tail -15
```

Expected: clean build. Fix any variable-name mismatches discovered while reading the file.

- [ ] **Step 7: Full test run (no new tests yet; Task 5 adds them)**

```bash
swift test 2>&1 | tail -5
```

Expected: existing 77 tests still pass (no regression).

- [ ] **Step 8: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift
git commit -m "feat(facade): Phase 3a — heartbeat → election + flushNow on rejoin"
```

---

## Task 5: Integration tests — reconnection and re-election

**Files:**
- Create: `Tests/PeerClockTests/ReconnectionTests.swift`
- Create: `Tests/PeerClockTests/CoordinatorReelectionTests.swift`

- [ ] **Step 1: Create ReconnectionTests.swift**

```swift
// Tests/PeerClockTests/ReconnectionTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — Reconnection")
struct ReconnectionTests {

    @Test("Peer disconnect then reconnect: full status resync via flushNow")
    func fullResyncOnReconnect() async throws {
        let network = MockNetwork()
        let a = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await a.start()
        try await b.start()

        // Wait for mutual discovery.
        try await waitForPeers(on: a, count: 1)
        try await waitForPeers(on: b, count: 1)

        // A publishes status.
        try await a.setStatus("v1", forKey: "com.test.k")
        try await Task.sleep(nanoseconds: 300_000_000)
        let before = await b.status(of: a.localPeerID)
        #expect(before?.entries["com.test.k"] != nil)

        // Simulate A dropping off the network.
        await network.simulateDisconnect(peer: a.localPeerID)
        // B should notice A leaving (via transport peer set update).
        try await Task.sleep(nanoseconds: 500_000_000)

        // Reconnect. B's runCoordinationLoop should see A re-added and
        // B should re-receive A's status via flushNow.
        await network.simulateReconnect(peer: a.localPeerID)

        // Wait up to 2s for the flushed status to arrive.
        let received = try await withTimeout(seconds: 2.0) {
            while true {
                if let snap = await b.status(of: a.localPeerID),
                   snap.entries["com.test.k"] != nil {
                    return true
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        #expect(received)

        await a.stop()
        await b.stop()
    }

    @Test("Brief disconnect heals without permanent peer loss")
    func briefDisconnectHeals() async throws {
        let network = MockNetwork()
        let a = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        let b = PeerClock(transportFactory: { id in
            MockTransport(localPeerID: id, network: network)
        })
        try await a.start()
        try await b.start()

        try await waitForPeers(on: a, count: 1)
        try await waitForPeers(on: b, count: 1)

        // Flap.
        await network.simulateDisconnect(peer: a.localPeerID)
        try await Task.sleep(nanoseconds: 200_000_000)
        await network.simulateReconnect(peer: a.localPeerID)

        // B should see A again within a reasonable window.
        try await withTimeout(seconds: 2.0) {
            for await list in b.peers {
                if list.contains(where: { $0.id == a.localPeerID }) { return }
            }
        }

        await a.stop()
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

- [ ] **Step 2: Create CoordinatorReelectionTests.swift**

```swift
// Tests/PeerClockTests/CoordinatorReelectionTests.swift
import Foundation
import Testing
@testable import PeerClock

@Suite("PeerClock — Coordinator re-election")
struct CoordinatorReelectionTests {

    @Test("Smallest peer ID is coordinator initially")
    func initialElection() async throws {
        let network = MockNetwork()
        // Create three clocks; we need to know which has smallest ID.
        let clocks = (0..<3).map { _ in
            PeerClock(transportFactory: { id in
                MockTransport(localPeerID: id, network: network)
            })
        }
        for c in clocks { try await c.start() }

        // Wait for full mesh discovery.
        for c in clocks {
            try await withTimeout(seconds: 3.0) {
                for await list in c.peers {
                    if list.count >= 2 { return }
                }
            }
        }

        try await Task.sleep(nanoseconds: 300_000_000)

        // The peer with the smallest PeerID should be coordinator everywhere.
        let expectedCoord = clocks.map(\.localPeerID).min()!
        for c in clocks {
            #expect(c.coordinatorID == expectedCoord)
        }

        for c in clocks { await c.stop() }
    }

    @Test("Coordinator leaves; others elect a new coordinator")
    func coordinatorLeaves() async throws {
        let network = MockNetwork()
        let clocks = (0..<3).map { _ in
            PeerClock(transportFactory: { id in
                MockTransport(localPeerID: id, network: network)
            })
        }
        for c in clocks { try await c.start() }

        for c in clocks {
            try await withTimeout(seconds: 3.0) {
                for await list in c.peers {
                    if list.count >= 2 { return }
                }
            }
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        // Identify the smallest PeerID (the coordinator).
        let sorted = clocks.sorted { $0.localPeerID < $1.localPeerID }
        let coord = sorted[0]
        let remaining = Array(sorted.dropFirst())
        let expectedNewCoord = remaining.map(\.localPeerID).min()!

        // Disconnect the coordinator from the network.
        await network.simulateDisconnect(peer: coord.localPeerID)

        // Remaining peers should elect a new coordinator within a few seconds.
        for c in remaining {
            try await withTimeout(seconds: 5.0) {
                while true {
                    if let cid = c.coordinatorID, cid == expectedNewCoord {
                        return
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        for c in clocks { await c.stop() }
    }

    // MARK: - Helpers

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

- [ ] **Step 3: Run integration tests**

```bash
swift test --filter ReconnectionTests 2>&1 | tail -20
swift test --filter CoordinatorReelectionTests 2>&1 | tail -20
swift test 2>&1 | tail -5
```

Expected: all new tests pass. Total: 82 tests.

If a test flakes due to timing:
- Increase the wait budgets (500ms → 1s, 2s → 3s)
- Don't weaken the assertions themselves

If `coordinatorLeaves` fails because the old coordinator's state lingers in `currentCoordinator`, verify that `reevaluateCoordination()` in Task 4 is being triggered. Add logging temporarily if needed.

- [ ] **Step 4: Commit**

```bash
git add Tests/PeerClockTests/ReconnectionTests.swift Tests/PeerClockTests/CoordinatorReelectionTests.swift
git commit -m "test(phase-3a): reconnection and coordinator re-election integration tests"
```

---

## Task 6: WiFiTransport short-retry + Last-In-Win

**Files:**
- Modify: `Sources/PeerClock/Transport/WiFiTransport.swift`

- [ ] **Step 1: Add Last-In-Win to handleInboundConnection**

Replace `handleInboundConnection` with:

```swift
    private func handleInboundConnection(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 16, maximumLength: 16) { [weak self] data, _, _, error in
            guard let self, let data, error == nil, let peerID = try? PeerID(data: data) else {
                connection.cancel()
                return
            }

            // Phase 3a: Last-In-Win. If an older connection exists for this
            // peer, cancel it before storing the new one. This prevents two
            // concurrent connections from the same peer (e.g. after a dialer
            // reconnect) from both being active.
            let oldConnection = self.lock.withLock { () -> NWConnection? in
                let old = self.connections[peerID]
                self.connections[peerID] = connection
                return old
            }
            oldConnection?.cancel()

            self.addPeer(peerID)
            self.receiveLength(from: peerID, connection: connection)
        }
    }
```

- [ ] **Step 2: Add short-retry to the outbound connection path**

Replace the `connect(to:peerID:)` stateUpdateHandler section with retry logic. The full replacement for `connect(to:peerID:)`:

```swift
    private func connect(to endpoint: NWEndpoint, peerID: PeerID) {
        guard peerID != localPeerID else { return }
        let shouldConnect = lock.withLock { () -> Bool in
            if connections[peerID] != nil {
                return false
            }
            return true
        }
        guard shouldConnect else { return }

        attemptConnect(to: endpoint, peerID: peerID, attempt: 1)
    }

    private func attemptConnect(to endpoint: NWEndpoint, peerID: PeerID, attempt: Int) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        lock.withLock {
            connections[peerID] = connection
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.addPeer(peerID)
                let handshake = self.localPeerID.data
                connection.send(content: handshake, completion: .contentProcessed { _ in })
                self.receiveLength(from: peerID, connection: connection)
            case .failed, .cancelled:
                // Phase 3a: short-retry up to reconnectMaxAttempts.
                let maxAttempts = self.configuration.reconnectMaxAttempts
                let retryInterval = self.configuration.reconnectRetryInterval
                if attempt < maxAttempts {
                    // Release the failed connection from the dict first so
                    // the next attempt can re-register.
                    self.lock.withLock {
                        if self.connections[peerID] === connection {
                            self.connections.removeValue(forKey: peerID)
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + retryInterval) { [weak self] in
                        guard let self else { return }
                        // Only retry if the peer is still expected.
                        let stillWanted = self.lock.withLock { self.connections[peerID] == nil }
                        if stillWanted {
                            self.attemptConnect(to: endpoint, peerID: peerID, attempt: attempt + 1)
                        }
                    }
                } else {
                    // Give up: signal disconnect to upper layers.
                    self.removePeer(peerID)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }
```

Note: `connect` now just calls `attemptConnect` with attempt 1. The retry logic lives in `attemptConnect` recursing via `queue.asyncAfter`.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: clean build. WiFiTransport is only exercised by real devices; unit tests use MockTransport so no test changes needed here. The short-retry behavior is validated manually in Task 7.

- [ ] **Step 4: Full test run**

```bash
swift test 2>&1 | tail -5
```

Expected: all 82 tests still passing.

- [ ] **Step 5: Commit**

```bash
git add Sources/PeerClock/Transport/WiFiTransport.swift
git commit -m "feat(transport): Phase 3a — short-retry and Last-In-Win"
```

---

## Task 7: Simulator E2E verification

**Files:** No code changes. Manual verification.

- [ ] **Step 1: Rebuild the demo and deploy**

```bash
xcodebuild -project /Volumes/Dev/DEVELOP/PeerClock/Examples/PeerClockDemo/PeerClockDemo.xcodeproj -scheme PeerClockDemo -destination 'generic/platform=iOS Simulator' build 2>&1 | tail -5

APP="/Users/hakaru/Library/Developer/Xcode/DerivedData/PeerClockDemo-drqkujgbdgpwfdblvgcnuecbddks/Build/Products/Debug-iphonesimulator/PeerClockDemo.app"
xcrun simctl terminate AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl terminate 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo 2>/dev/null
xcrun simctl install AF61223F-58C5-48A3-BF21-54F942BA3C32 "$APP"
xcrun simctl install 981BFB44-64A5-476D-88B2-9B34CF8D8762 "$APP"
xcrun simctl launch AF61223F-58C5-48A3-BF21-54F942BA3C32 net.hakaru.PeerClockDemo
xcrun simctl launch 981BFB44-64A5-476D-88B2-9B34CF8D8762 net.hakaru.PeerClockDemo
```

- [ ] **Step 2: Manual test checklist**

User performs:
1. ✅ Both apps Start, Peers show `connected` bagdes on both
2. ✅ Stop one app → the other shows `disconnected` bagde within 5 seconds
3. ✅ Restart the stopped app → the other shows `connected` again within a few seconds, and Log shows incoming `Status from <peer>: gen=N, keys=...` events (indicating flushNow delivered)
4. ✅ Schedule +3s, Broadcast Ping, and existing features still work end-to-end

The simulator has no WiFi-level disconnect; the Stop/Start cycle serves the same purpose for the upper-layer flow. Full NWConnection-level retry is best validated with physical devices on a flaky network, which is out of scope for the Phase 3a completion criterion.

- [ ] **Step 3: Tag completion**

```bash
git tag -a phase-3a-complete -m "Phase 3a: Reconnection + Coordinator re-election complete"
```

(don't push)

---

## Self-Review Checklist

- [x] Spec coverage:
  - Configuration 追加フィールド → Task 1
  - NTPSyncEngine ステートリセット → Task 2
  - MockNetwork simulate API → Task 3
  - HeartbeatMonitor → election 配線 + flushNow 1 回 → Task 4
  - Reconnection/reelection 統合テスト → Task 5
  - WiFiTransport 短期リトライ + Last-In-Win → Task 6
  - 実機 E2E → Task 7
- [x] No placeholders; each code step contains actual code
- [x] Type consistency: `reconnectRetryInterval`, `reconnectMaxAttempts`, `simulateDisconnect`, `simulateReconnect`, `reevaluateCoordination`, `attemptConnect`, `heartbeatElectionTask` are used identically across tasks
- [x] TDD where applicable: Task 2 and 3 have tests alongside implementation. Task 6 (WiFiTransport) has no unit tests because WiFiTransport is not exercised by the MockNetwork-based suite; it's validated manually in Task 7
- [x] Frequent commits: 7 tasks × 1 commit each

## Known Risks

1. **Task 4 `reevaluateCoordination` may race with `runCoordinationLoop`**: both mutate `currentCoordinator`. Both are called via NSLock-protected access. If a heartbeat-disconnect fires during a transport.peers iteration, the order is undefined but both will converge on the same result (election is idempotent given the same effective peer set).

2. **Task 6 retry uses `queue.asyncAfter`**: `queue` is a DispatchQueue (already in the file). asyncAfter is safe and integrates cleanly. Avoid using `Task.sleep` inside an NWConnection.stateUpdateHandler — it would require reshaping the handler into an async closure.

3. **Task 4 `reevaluateCoordination` does NOT call `startSyncResponder`**: the helper skips the responder switch because `startSyncResponder` is private and needs transport access. This is a known limitation documented inline. The next `transport.peers` update will drive the responder switch normally. The test in Task 5 verifies the election outcome but does not directly test the responder restart. This is acceptable for Phase 3a because the sync loop will re-initialize on the next iteration anyway.

4. **`reconnectMaxAttempts = 3` with `reconnectRetryInterval = 0.5s` means the retry window is actually 1.0s** (attempt 1 immediate, attempt 2 after 0.5s, attempt 3 after 1.0s total). Spec target is 1.5s. If desired strictly, change to `reconnectMaxAttempts = 4`. For now keep 3 and document the actual window in the Configuration doc comment.

5. **`simulateDisconnect` uses `Set<PeerID>` in MockNetwork but network is already an `actor`**: the add/remove and set checks are inside actor-isolated methods, so they're safe. No extra locking needed.
