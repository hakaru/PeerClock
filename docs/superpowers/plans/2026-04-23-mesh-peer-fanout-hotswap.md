# PeerClock — Mesh Peer Fan-Out + AutoRuntime Hot-Swap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make `.auto` topology transitions fire under real mesh peer discovery, and make those transitions actually re-wire `PeerClock`'s downstream services (NTPSync / CommandRouter / Heartbeat / Status / Drift) against the new (star) transport.

**Context:** Tech debt #25 from the v0.4.0 dual-topology plan. v0.4.0 shipped `.auto` topology as a public API but left two coupled gaps:

1. `MeshRuntime.peerStream` is a never-yielding placeholder — `transport.peers` is a single-consumer `AsyncStream` already consumed by `PeerClock.runCoordinationLoop`, so `MeshRuntime` can't observe peers.
2. `AutoRuntime.transitionToStar` flips only an internal `_mode` flag — `PeerClock.start()` snapshots `rt.transport` once and downstream services stay bound to the mesh transport after "transition."

Either fix in isolation is useless: #1 alone makes the transition fire but have no effect; #2 alone has nothing to trigger it.

**Architecture:**
- **Part A (fan-out):** `MeshRuntime` internalizes the single-consumer `transport.peers` stream and fans out to N subscribers via a lightweight subscriber registry (`PeerStreamFanOut`). `PeerClock.runCoordinationLoop` subscribes instead of reading `transport.peers` directly; `AutoRuntime` also subscribes to detect the threshold crossing.
- **Part B (hot-swap):** Control inversion. `AutoRuntime` no longer self-swaps — it emits a `TransitionReady` event on a new `TopologyRuntime.transitionEvents` stream. `PeerClock` owns the orchestration: on `TransitionReady`, it tears down downstream services, asks `AutoRuntime.performTransition()` to swap inner runtime, then rebuilds services against `runtime.transport` (now the star transport).
- Wire format untouched. No public-API break. No new external dependencies.

**Tech Stack:** Swift 6.0 strict concurrency, `AsyncStream` fan-out, `NSLock` coordination. No external deps (per CLAUDE.md).

**Branch (target):** `feat/v0.4.1-peer-fanout-hotswap` (recommendation — see Phase 0). Branches from `feat/v0.4-dual-topology` or `v0.4.0` tag once cut.

**Out of scope (explicitly deferred):**
- Reverse transition (star→mesh). v0.4.0 said "no reverse"; this plan keeps that.
- Fan-out for Multipeer / Star / Failover transports. Only mesh's `WiFiTransport.peers` needs fan-out.
- Pushing service ownership (NTPSync / CommandRouter / heartbeat / status / drift) down into runtimes. That's a larger architectural refactor (v0.5+). This plan keeps services owned by `PeerClock` and teaches it to rebuild them.
- Graceful handoff during transition (in-flight commands may be dropped during the ~100ms service-restart window). A best-effort re-send layer is a future concern.

---

## Phase 0 — Branching decision (no code)

Before starting execution, decide the target release. This is a **user decision**; flag it and wait.

- **Option A: 0.4.1 bugfix branch.** v0.4.0 ships with partly-non-functional `.auto`; closing the gap in 0.4.1 respects the API contract shipped. Low risk: no breaking changes expected.
- **Option B: 0.5.0 feature branch.** If additional breaking changes are queued (e.g. pushing services into runtimes for good), bundle. Higher risk: more in-flight changes.

Recommendation: **Option A**. The fix is self-contained and honors the 0.4.0 API.

- [ ] **Step 1: User picks A or B. Branch accordingly.**

---

## File Structure

**New:**
- `Sources/PeerClock/Facade/PeerStreamFanOut.swift` — subscriber registry for `[Peer]` updates
- `Sources/PeerClock/Facade/TopologyTransition.swift` — `TopologyTransition` event type
- `Tests/PeerClockTests/PeerStreamFanOutTests.swift`
- `Tests/PeerClockTests/MeshPeerFanOutTests.swift` — integration of fan-out into MeshRuntime
- `Tests/PeerClockTests/AutoTransitionIntegrationTests.swift` — end-to-end transition test

**Modified:**
- `Sources/PeerClock/Facade/TopologyRuntime.swift` — add `transitionEvents` to protocol
- `Sources/PeerClock/Facade/MeshRuntime.swift` — internalize `transport.peers`, expose fan-out, real `currentPeerCount`
- `Sources/PeerClock/Facade/StarRuntime.swift` — implement no-op `transitionEvents`
- `Sources/PeerClock/Facade/AutoRuntime.swift` — subscribe to inner mesh peer stream, emit `TransitionReady`, drop self-swap; expose `performTransition()`
- `Sources/PeerClock/PeerClock.swift` — subscribe to `runtime.peerStream` and `runtime.transitionEvents`; add `restartServices(transport:)`; orchestrate swap
- `Tests/PeerClockTests/AutoTopologyTransitionTests.swift` — update tests to reflect the new control flow
- `CHANGELOG.md` — 0.4.1 (or 0.5.0) entry

---

## Phase 1 — Peer-stream fan-out primitive

### Task 1.1: `PeerStreamFanOut` subscriber registry

**Files:**
- Create: `Sources/PeerClock/Facade/PeerStreamFanOut.swift`
- Create: `Tests/PeerClockTests/PeerStreamFanOutTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import Testing
import Foundation
@testable import PeerClock

@Suite("PeerStreamFanOut")
struct PeerStreamFanOutTests {

    @Test("two subscribers receive identical publish sequence")
    func twoSubscribersAgree() async throws {
        let fanOut = PeerStreamFanOut<[Peer]>()
        let a = fanOut.subscribe()
        let b = fanOut.subscribe()

        fanOut.publish([Peer(id: PeerID(UUID()), state: .connected)])
        fanOut.publish([])

        var ait = a.makeAsyncIterator()
        var bit = b.makeAsyncIterator()
        let a0 = await ait.next()
        let b0 = await bit.next()
        let a1 = await ait.next()
        let b1 = await bit.next()

        #expect(a0?.count == 1)
        #expect(b0?.count == 1)
        #expect(a1?.count == 0)
        #expect(b1?.count == 0)
    }

    @Test("finish completes all active subscribers")
    func finishCompletes() async throws {
        let fanOut = PeerStreamFanOut<[Peer]>()
        let s = fanOut.subscribe()
        fanOut.finish()
        var it = s.makeAsyncIterator()
        let r = await it.next()
        #expect(r == nil)
    }
}
```

- [ ] **Step 2: Implement `PeerStreamFanOut`**

```swift
import Foundation

/// Thread-safe 1-to-N broadcaster for `AsyncStream`-style delivery.
///
/// One publish call reaches all live subscribers. Unsubscription is implicit
/// via `AsyncStream` termination (task cancellation finishes the iterator).
internal final class PeerStreamFanOut<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var finished: Bool = false
    private var last: Value?

    internal func subscribe(replayLast: Bool = true) -> AsyncStream<Value> {
        AsyncStream { cont in
            let id = UUID()
            lock.withLock {
                if finished {
                    cont.finish()
                    return
                }
                if replayLast, let last {
                    cont.yield(last)
                }
                continuations[id] = cont
            }
            cont.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    internal func publish(_ value: Value) {
        let (shouldYield, conts) = lock.withLock { () -> (Bool, [AsyncStream<Value>.Continuation]) in
            guard !finished else { return (false, []) }
            last = value
            return (true, Array(continuations.values))
        }
        guard shouldYield else { return }
        for c in conts { c.yield(value) }
    }

    internal func finish() {
        let conts = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            finished = true
            let cs = Array(continuations.values)
            continuations.removeAll()
            return cs
        }
        for c in conts { c.finish() }
    }

    internal var lastValue: Value? {
        lock.withLock { last }
    }
}
```

- [ ] **Step 3: Run** `swift test --filter PeerStreamFanOut` — expect pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Facade/PeerStreamFanOut.swift Tests/PeerClockTests/PeerStreamFanOutTests.swift
git commit -m "feat(facade): PeerStreamFanOut — 1:N broadcast for AsyncStream delivery"
```

### Task 1.2: `MeshRuntime` adopts fan-out + real `currentPeerCount`

**Files:**
- Modify: `Sources/PeerClock/Facade/MeshRuntime.swift`
- Create: `Tests/PeerClockTests/MeshPeerFanOutTests.swift`

- [ ] **Step 1: Replace placeholder `peerStream` + `currentPeerCount` with fan-out-backed real values**

`MeshRuntime` gains a `PeerStreamFanOut<[Peer]>` member. In `start()`, spawn an internal Task that iterates `transport.peers` and publishes mapped `[Peer]` values to the fan-out. `peerStream` becomes `fanOut.subscribe()`. `currentPeerCount` returns `fanOut.lastValue?.count ?? 0`.

Also expose a new internal method `subscribePeers() -> AsyncStream<[Peer]>` that any other component (PeerClock.runCoordinationLoop, AutoRuntime) can call.

- [ ] **Step 2: Add integration test**

`Tests/PeerClockTests/MeshPeerFanOutTests.swift`:

```swift
import Testing
import Foundation
@testable import PeerClock

@Suite("MeshRuntime peer fan-out")
struct MeshPeerFanOutTests {
    @Test("two independent subscribers both see peer updates") // via MockTransport + MockNetwork
    func twoSubscribersAgree() async throws {
        let network = MockNetwork()
        let a = PeerID(UUID())
        let b = PeerID(UUID())
        let transportA = network.createTransport(for: a)
        let rt = MeshRuntime(transport: transportA)
        try await rt.start()
        defer { Task { await rt.stop() } }

        let s1 = rt.subscribePeers()
        let s2 = rt.subscribePeers()

        // Trigger discovery by starting a second peer
        let transportB = network.createTransport(for: b)
        try await transportB.start()
        defer { Task { await transportB.stop() } }

        var it1 = s1.makeAsyncIterator()
        var it2 = s2.makeAsyncIterator()
        let seen1 = try await withTimeout(seconds: 2) { await it1.next() ?? [] }
        let seen2 = try await withTimeout(seconds: 2) { await it2.next() ?? [] }

        #expect(seen1.contains { $0.id == b } == seen2.contains { $0.id == b })
    }

    // inline withTimeout helper, as other test files do
}
```

- [ ] **Step 3: Run full suite** — no regressions, new test passes.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/Facade/MeshRuntime.swift Tests/PeerClockTests/MeshPeerFanOutTests.swift
git commit -m "feat(mesh): MeshRuntime fans out transport.peers; real currentPeerCount"
```

### Task 1.3: `PeerClock.runCoordinationLoop` consumes `runtime.peerStream`

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`

**Intent:** remove the direct `for await peerIDs in transport.peers` iteration in `runCoordinationLoop`. Instead, subscribe to `runtime.peerStream` (mesh/auto). For `.star` topology, `runCoordinationLoop` is semantically meaningless (coord is a mesh concept) — either no-op or skip entirely for star.

- [ ] **Step 1: Adjust `runCoordinationLoop` signature to take a `peerStream` instead of a transport**

- [ ] **Step 2: In `start()`, pass `runtime.peerStream` (not `transport.peers`) for mesh/auto; skip coord loop entirely for `.star`**

- [ ] **Step 3: Verify existing mesh-topology tests still pass — this is the highest-risk step**

```bash
swift test --filter CoordinatorReelection 2>&1 | tail -10
swift test --filter ElectionMatrix 2>&1 | tail -10
swift test 2>&1 | tail -3
```

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift
git commit -m "refactor(facade): runCoordinationLoop consumes runtime.peerStream not transport.peers"
```

---

## Phase 2 — `TransitionReady` event surface

### Task 2.1: `TopologyTransition` type + protocol addition

**Files:**
- Create: `Sources/PeerClock/Facade/TopologyTransition.swift`
- Modify: `Sources/PeerClock/Facade/TopologyRuntime.swift`
- Modify: `Sources/PeerClock/Facade/MeshRuntime.swift` (no-op stream)
- Modify: `Sources/PeerClock/Facade/StarRuntime.swift` (no-op stream)

- [ ] **Step 1: Define the event**

```swift
// Sources/PeerClock/Facade/TopologyTransition.swift
import Foundation

/// Event emitted by a topology runtime when it's ready to transition its
/// underlying component stack (e.g. `.auto` mesh → star crossing a threshold).
///
/// `PeerClock` receives this and orchestrates a service-layer rebuild against
/// the new transport.
internal struct TopologyTransition: Sendable, Equatable {
    internal enum Kind: Sendable, Equatable { case meshToStar }
    internal let kind: Kind
    internal let at: Date
}
```

- [ ] **Step 2: Add to protocol**

```swift
internal protocol TopologyRuntime: AnyObject, Sendable {
    // ... existing members ...
    var transitionEvents: AsyncStream<TopologyTransition> { get }
}
```

- [ ] **Step 3: MeshRuntime and StarRuntime provide empty streams**

Each adds:
```swift
let transitionEvents: AsyncStream<TopologyTransition>
private let transitionEventsContinuation: AsyncStream<TopologyTransition>.Continuation
// init initializes, finish on stop()
```

They never yield.

- [ ] **Step 4: Run tests** — existing topology tests must still pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PeerClock/Facade/
git commit -m "feat(facade): TopologyTransition event surface on TopologyRuntime protocol"
```

### Task 2.2: `AutoRuntime` emits `TransitionReady`; drops self-swap

**Files:**
- Modify: `Sources/PeerClock/Facade/AutoRuntime.swift`
- Modify: `Tests/PeerClockTests/AutoTopologyTransitionTests.swift`

- [ ] **Step 1: Add `performTransition()` — the method PeerClock will call to complete the swap**

```swift
/// Called by `PeerClock` after it has drained downstream services.
/// Swaps the active inner runtime from mesh to star and forwards the star's
/// connectionEvents.
internal func performTransition() async throws {
    guard lock.withLock({ _mode == .mesh }) else { return }
    let old = lock.withLock { () -> (any TopologyRuntime)? in
        let o = active; return o
    }
    await old?.stop()
    let star = StarRuntime(localPeerID: localPeerID, role: .auto, configuration: configuration)
    try await star.start()
    lock.withLock {
        self.active = star
        self._mode = .star
    }
    spawnConnectionEventForwarder(from: star)
}
```

- [ ] **Step 2: Refactor internal threshold logic to emit `TransitionReady` instead of swapping directly**

Replace the old `private func transitionToStar() async` body with:

```swift
private func announceTransitionReady() {
    let event = TopologyTransition(kind: .meshToStar, at: Date())
    transitionEventsContinuation.yield(event)
    // Do NOT perform the swap here. PeerClock orchestrates via performTransition().
}
```

`onPeerCount` now schedules `announceTransitionReady` after settle, not the swap.

- [ ] **Step 3: Subscribe to the inner mesh runtime's peer stream for real observation**

In `start()`:
```swift
let mesh = MeshRuntime(transport: WiFiTransport(localPeerID: localPeerID, configuration: configuration))
try await mesh.start()
lock.withLock { self.active = mesh }
Task { [weak self] in
    for await peers in mesh.subscribePeers() {
        await self?.onPeerCountObservation(peers.count)
    }
}
```

This replaces the test-hook-only observation path.

- [ ] **Step 4: Keep `testHook_injectDiscoveredPeers` for unit tests — it now calls `announceTransitionReady` directly (still useful)**

- [ ] **Step 5: Update `AutoTopologyTransitionTests` to reflect the new contract**

Tests assert that after settle, `rt.testHook_currentMode == .mesh` still (the swap is now PeerClock's job) but a `TransitionReady` event was published:

```swift
@Test("threshold crossing emits TransitionReady on transitionEvents")
func emitsTransitionReady() async throws {
    let rt = AutoRuntime(
        localPeerID: PeerID(UUID()),
        heuristic: .peerCountThreshold(3),
        configuration: .default,
        settleWindow: .milliseconds(50)
    )
    try await rt.start()
    var it = rt.transitionEvents.makeAsyncIterator()
    rt.testHook_injectDiscoveredPeers(count: 3)
    let evt = try await withTimeout(seconds: 1) { await it.next() }
    #expect(evt?.kind == .meshToStar)
    await rt.stop()
}
```

- [ ] **Step 6: Run tests** — `AutoTopology*` tests all green.

- [ ] **Step 7: Commit**

```bash
git add Sources/PeerClock/Facade/AutoRuntime.swift Tests/PeerClockTests/AutoTopologyTransitionTests.swift
git commit -m "refactor(auto): emit TransitionReady instead of self-swapping; add performTransition()"
```

---

## Phase 3 — `PeerClock` orchestrates hot-swap

### Task 3.1: `restartServices(transport:)` internal

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`

**Intent:** extract the service-wiring code currently in `start()` into a private helper so it can be called both initially AND on transition. The helper takes the new transport, tears down any existing service state, and rebuilds everything against the new transport.

Pseudocode:
```swift
private func restartServices(transport: any Transport) async {
    // 1. Tear down existing (if any)
    let oldTasks = lock.withLock {
        let o = (coordinationTask, syncResponderTask, /* ... */)
        coordinationTask = nil; syncResponderTask = nil; /* ... */
        return o
    }
    // Cancel + await in parallel (mirror existing stop() parallel pattern)
    // ...
    await existingServices.shutdown()  // similar parallel pattern

    // 2. Build new
    lock.withLock {
        self.transport = transport
        let elec = CoordinatorElection(localPeerID: localPeerID)
        self.election = elec
        let router = CommandRouter(transport: transport, localPeerID: localPeerID)
        self.commandRouter = router
        // ... NTPSync, DriftMonitor, EventScheduler, StatusRegistry, etc.
    }
    // 3. Respawn routing tasks
    // (use existing code path from start())
}
```

- [ ] **Step 1: Extract the wiring body into `restartServices(transport:)` — do NOT change behavior yet; `start()` calls `restartServices(transport: rt.transport)` at end**

- [ ] **Step 2: Ensure `restartServices` can be called again mid-lifetime without side effects on non-service state (topology, localPeerID, configuration, runtime)**

- [ ] **Step 3: Run existing tests** — 239 still passing.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift
git commit -m "refactor(facade): extract restartServices(transport:) from start()"
```

### Task 3.2: PeerClock subscribes to `runtime.transitionEvents`

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`

- [ ] **Step 1: After `rt.start()` in `start()`, spawn a subscriber task**

```swift
let transitionSubscriber = Task { [weak self] in
    for await event in rt.transitionEvents {
        await self?.handleTransition(event)
    }
}
// Track this task so stop() can cancel it.
```

- [ ] **Step 2: Implement `handleTransition`**

```swift
private func handleTransition(_ event: TopologyTransition) async {
    guard case .meshToStar = event.kind else { return }
    guard let auto = lock.withLock({ runtime as? AutoRuntime }) else { return }
    do {
        try await auto.performTransition()
        let newTransport = lock.withLock { runtime?.transport }
        if let newTransport {
            await restartServices(transport: newTransport)
        }
    } catch {
        pcLogger.error("[PeerClock] transition failed: \(String(describing: error), privacy: .public)")
    }
}
```

- [ ] **Step 3: Verify transition subscriber is cancelled in `stop()` alongside other routing tasks** — add to the parallel `async let` cleanup pattern.

- [ ] **Step 4: Run full suite**

- [ ] **Step 5: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift
git commit -m "feat(facade): orchestrate auto-topology hot-swap via TransitionReady subscriber"
```

---

## Phase 4 — End-to-end integration test

### Task 4.1: `AutoTransitionIntegrationTests`

**Files:**
- Create: `Tests/PeerClockTests/AutoTransitionIntegrationTests.swift`

- [ ] **Step 1: Write the integration test**

```swift
import Testing
import Foundation
@testable import PeerClock

@Suite("Auto topology — end-to-end transition")
struct AutoTransitionIntegrationTests {

    @Test("peer count crossing triggers full swap to StarTransport")
    func meshToStarSwap() async throws {
        // Create PeerClock with .auto + tiny settle window
        // (requires a test-only init overload on AutoRuntime or a facade hook
        //  that lets us pass settleWindow — coordinate this change with Phase 2)
        let pc = PeerClock(topology: .auto(heuristic: .peerCountThreshold(3)))
        try await pc.start()
        defer { Task { await pc.stop() } }

        // Confirm initial transport is WiFiTransport (mesh)
        // (may need a testHook_currentTransportKind: String property)

        // Inject peers via AutoRuntime test hook (accessible through
        // PeerClock.testHook_runtime for this test only, DEBUG-gated)
        await pc.testHook_injectAutoPeers(count: 3)

        // Wait ~200ms for settle + transition
        try await Task.sleep(for: .milliseconds(200))

        // Confirm transport is now StarTransport
        #expect(pc.testHook_currentTransportKind == "StarTransport")
    }
}
```

Add the necessary DEBUG-only hooks to `PeerClock` (`testHook_injectAutoPeers`, `testHook_currentTransportKind`).

- [ ] **Step 2: Run** `swift test --filter AutoTransition 2>&1 | tail -10` — expect pass.

- [ ] **Step 3: If flaky** (timing of transition settle), increase `settleWindow` in the test and `Task.sleep` proportionally. If genuinely racy, instrument with a dedicated `completed` continuation that fires when `restartServices` returns.

- [ ] **Step 4: Commit**

```bash
git add Sources/PeerClock/PeerClock.swift Tests/PeerClockTests/AutoTransitionIntegrationTests.swift
git commit -m "test(auto): end-to-end mesh→star transition via PeerClock"
```

---

## Phase 5 — Cleanup

### Task 5.1: Remove the tech-debt marker

- [ ] **Step 1: Update `Sources/PeerClock/Facade/MeshRuntime.swift`** — remove the "Phase 2 scope: ... never yield ..." doc comment about the placeholder; replace with the real description.

- [ ] **Step 2: Update `Sources/PeerClock/Facade/AutoRuntime.swift`** — remove the "Scope limitation ... deferred (see tech-debt task)" block.

- [ ] **Step 3: Commit**

```bash
git add Sources/PeerClock/Facade/
git commit -m "docs: drop placeholder/tech-debt notes now that peer fan-out + hot-swap land"
```

### Task 5.2: CHANGELOG

- [ ] **Step 1: Prepend 0.4.1 entry (or expand 0.5.0 preamble if Option B)**

```markdown
## [0.4.1] — Unreleased

**`.auto` topology transitions now actually transition.** Closes the v0.4.0 gap
where `.auto(peerCountThreshold:)` could detect the threshold crossing in tests
but not in production, and where the transition was logical-only — downstream
services (NTPSync / CommandRouter / heartbeat / status / drift) continued
pointing to the mesh transport after a "transition."

### Changed

- `MeshRuntime.peerStream` now yields real peer updates (was a placeholder).
- `MeshRuntime.currentPeerCount` returns the real count (was always 0).
- `AutoRuntime` no longer self-swaps its inner runtime. Instead it emits a
  `TopologyTransition` on a new `TopologyRuntime.transitionEvents` stream;
  `PeerClock` orchestrates the swap + rebuilds services against the new
  transport.
- `PeerClock.runCoordinationLoop` consumes `runtime.peerStream` instead of
  `transport.peers` directly. Observable behavior unchanged for mesh.

### Added (internal)

- `PeerStreamFanOut` — 1:N broadcaster for `AsyncStream` delivery.
- `TopologyTransition` — event type on the new `transitionEvents` stream.
```

- [ ] **Step 2: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): 0.4.1 — real auto-transition"
```

---

## Acceptance criteria (pre-merge checklist)

- [ ] `MeshRuntime.currentPeerCount` returns real count (integration-tested).
- [ ] `AutoRuntime` emits `TransitionReady` on threshold; does not self-swap.
- [ ] `PeerClock.handleTransition` rebuilds services against new transport.
- [ ] `AutoTransitionIntegrationTests/meshToStarSwap` passes: `PeerClock(topology: .auto)` → after peer threshold, transport is `StarTransport`.
- [ ] Full suite: ≥ baseline (239 at start of this plan) still passing.
- [ ] No public API break.
- [ ] `connectionEvents` stream survives transition (events before and after both delivered).
- [ ] Tech-debt #25 marker removed from source and plan-tracking task list.

---

## Risks

1. **Service restart races.** Between service teardown and rebuild (~50-100ms), any `commands` / `sync` activity is dropped silently. Mitigation: document as known; an at-most-once delivery layer is out of scope. Loud logging during the window.
2. **MockTransport-based Bonjour discovery flakes in CI.** The Phase 1 Task 1.2 test spins up two real MockTransports on a simulated network. If MockNetwork delivery isn't deterministic, broaden timeouts. If needed, unit-test fan-out only at the `PeerStreamFanOut` level and relegate integration to a dedicated integration suite skipped in CI.
3. **StarRuntime.start() in Phase 4 test.** Starting star in a unit test needs real `NWListener` capability. If test environment denies network permission, integration test may need a Mock-backed star path — not in scope. If that blocks Phase 4, flag and descope the integration test, keeping unit-level coverage only.
4. **Connection events continuity.** `PeerClock.connectionEvents` subscribes to `runtime.connectionEvents`. When `runtime` is an `AutoRuntime`, that runtime re-subscribes on transition (already wired in v0.4.0). The subscription on PeerClock doesn't change. Verify with a dedicated test if there's any surprise.

---

## Self-Review (pre-execution)

- **Coverage of tech-debt #25:** Part A (fan-out) → Phase 1; Part B (hot-swap) → Phase 3. Both ✓.
- **No wire-format changes:** confirmed. All changes are control-plane.
- **No public API break:** `MeshRuntime`, `AutoRuntime`, `TopologyRuntime`, `PeerStreamFanOut`, `TopologyTransition` are all internal. `PeerClock`'s public surface is unchanged.
- **No new dependencies:** confirmed (`PeerStreamFanOut` is a hand-rolled 1:N broadcaster).
- **Test-hook proliferation:** this plan adds a couple of DEBUG-gated hooks (`PeerClock.testHook_injectAutoPeers`, `.testHook_currentTransportKind`). Acceptable — matches existing `testHook_*` conventions.
- **Reversibility:** if the plan derails mid-execution, each phase's commits are independent enough to revert or rebase cleanly.

## Post-review adjustments to apply during execution
- If Phase 1 Task 1.3 (runCoordinationLoop refactor) exposes existing tests depending on `transport.peers` iteration order/timing, patch those tests to use the new subscription surface instead of asserting on order.
- If Phase 2 Task 2.2 tests flake on the `TransitionReady` receive timing, increase settle window to 100ms and rely on `testHook_waitForSettleWindow` if it still exists; otherwise add one.
- If Phase 4 integration test can't spin up a real StarTransport in the test environment, descope it to a mocked-runtime test.

---

## Execution notes for the orchestrator

- Expected total work: ~4-6 hours focused, ~1 day with pauses.
- Each phase ends in a runnable state — CI should be green after every commit.
- Phase 1 Task 1.3 is the highest-risk commit (touches mesh's coord loop). Keep the diff surgical; run the full mesh test suite after.
- If the branch decision in Phase 0 is Option B (0.5.0), append any other queued breaking changes to this plan's scope before executing.
