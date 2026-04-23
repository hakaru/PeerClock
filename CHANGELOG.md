# Changelog

All notable changes to PeerClock are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.4.2] — 2026-04-23

Safety patch from a post-release Codex + Gemini independent review of v0.4.1. Two race conditions and one test-coverage gap closed.

### Fixed

- **stop() vs in-flight auto-topology transition** race: if `stop()` ran while `handleTransition` was processing a `.meshToStar` event, the transition could complete after teardown and spawn new services on a stopped `PeerClock`. Fix: serialize via a new `isStopped` flag — `stop()` sets it and waits for `isTransitioning` to clear; `handleTransition` and `performMeshToStarTransition` both early-return when stopped, so the service rebuild is skipped once shutdown has begun. Reset in `start()` for restart-after-stop.
- **Unsynchronized reads of mutable facade state.** `PeerClock.commands` and `PeerClock.now` read `commandRouter` / `syncEngine` without the lock while `restartServices` / `teardownServices` mutate them under it. Getters now take the lock for the property load.

### Added

- Regression tests:
  - `AutoHotSwapTests.stopRacesInFlightTransition` — async-let both paths, assert clean teardown.
  - `AutoHotSwapTests.restartAfterStop` — verify `isStopped` reset.
  - `PeerStreamFanOutTests.cancellationRemovesContinuation` — onTermination cleans up dict.
  - `PeerStreamFanOutTests.finishEmptiesDict` — finish() drops all subscribers.
  - `PeerStreamFanOutTests.subscribeAfterFinishNoLeak` — post-finish subscribe leaves no state.
- `PeerStreamFanOut.subscriberCount` DEBUG-only accessor for dict-size assertions.

### Known deferred to v0.5

- Public API surface cleanup: `HeartbeatMonitor`, `EventScheduler`, `StatusRegistry`, `StatusReceiver`, `Sleeper` family are `public` but should be `internal`. Demoting requires a breaking change to `heartbeatEvents: AsyncStream<HeartbeatMonitor.Event>` and siblings — reserved for a major bump.

## [0.4.1] — 2026-04-23

**`.auto` topology transitions now actually transition.** Closes the v0.4.0 gap
where `.auto(peerCountThreshold:)` could detect the threshold crossing in
tests but not in production, and where the transition was logical-only —
downstream services (NTPSync / CommandRouter / Heartbeat / Status / Drift)
continued pointing to the mesh transport even after a "transition."

### Added (internal)

- `PeerStreamFanOut` — thread-safe 1:N broadcaster for `AsyncStream` delivery.
- `TopologyTransition` + `TopologyRuntime.transitionEvents` — event surface so
  auto-topology can notify `PeerClock` of a ready transition.
- `PeerClock.testHook_injectAutoPeers` / `testHook_currentTransportKind` /
  `testHook_restartCount` / `testHook_forceMeshToStarTransition` (all DEBUG).

### Changed

- `MeshRuntime.subscribePeers()` and `MeshRuntime.peerStream` now yield real
  `[Peer]` values derived from `transport.peers` (previously placeholder).
  `MeshRuntime.currentPeerCount` returns the real count.
- `PeerClock.runCoordinationLoop` consumes `runtime.peerStream` instead of
  `transport.peers` directly. Observable behavior unchanged for mesh; the
  refactor enables multiple subscribers (coord loop + AutoRuntime observer).
- `AutoRuntime` no longer self-swaps its inner runtime. It emits a
  `TopologyTransition(kind: .meshToStar)` on its new `transitionEvents`
  stream; `PeerClock` orchestrates by calling `AutoRuntime.performTransition()`
  and then rebuilds services via `restartServices(transport:)`.
- `PeerClock.start()` and `stop()` are rewritten in terms of private
  `restartServices(transport:)` + `teardownServices()` helpers; behavior
  preserved.

### Fixed

- `AutoRuntime.testHook_injectDiscoveredPeers` no longer races with the real
  peer-observer task (which was immediately overwriting the injected count
  with `0` from empty `transport.peers` yields in unit-test environments).
  The DEBUG hook now cancels the real observer on first call.
- `AutoRuntime.performTransition()` is now rollback-safe: the new star runtime
  is started **before** the mesh runtime is stopped, so a failed
  `star.start()` leaves mesh alive and the service layer bound to a live
  transport instead of a stopped one.
- `PeerClock.handleTransition` gains a re-entrancy guard so a duplicate
  `.meshToStar` event (e.g. from the subscriber re-attaching after
  `restartServices`) does not trigger an extra teardown/rebuild.
- `AutoRuntime.spawnConnectionEventForwarder` now starts the new forwarder
  before cancelling the prior one (under one lock acquisition for the
  swap-and-assign), shrinking the handoff loss window during transition.

## [0.4.0] — 2026-04-23

**Dual topology.** `PeerClock` now supports `.mesh` (v0.2.x-compatible), `.star` (new WebSocket-based, host-elected), and `.auto` (starts mesh, switches to star at peer count threshold). The v0.3.0-beta.1 star work is now exposed through the unified facade rather than requiring manual transport factory wiring.

**v0.3.0 tag deprecated.** The previous `v0.3.0` tag was mislabeled (points to v0.2.x library code). v0.4.0 is the first version where `star` is a first-class facade mode. Consumers pinned to `from: "0.3.0"` should explicitly pin to `exactVersion: "0.4.0"` or `revision:` as appropriate.

### Added

- `Topology` enum: `.mesh`, `.star(role:)`, `.auto(heuristic:)`
- `PeerClock(topology:)` init parameter (default `.mesh`)
- `StarRole.clientOnly` for AUv3 extensions where `NWListener` is unsafe
- `AutoHeuristic.peerCountThreshold(N)` (default N=5)
- Star Bonjour service type `_peerclockstar._tcp` (separate from `_peerclock._tcp` to prevent mesh/star cross-discovery)
- `WireCompatGoldenTests` — byte-identity tests for mesh `MessageCodec` output vs v0.2.x fixtures
- `ConnectionEvent` observability type + `PeerClock.connectionEvents: AsyncStream<ConnectionEvent>` surfacing star handshake failures (`invalidUpgrade` / `badAcceptHash` / `oversizedFrame`), timeouts, and disconnects. Producers wired in StarClient / StarHost / StarTransport; mesh topology emits nothing.

### Changed

- `Transport.send(_:to:)` **removed** from the protocol. All delivery is via `broadcast(_:)`. Unicast semantics are now a recipient-filtering concern inside `CommandRouter` (uses existing `commandUnicast` wire type; filters at receive).
- `PeerClock.init(transportFactory:)` **removed** from public API. Internal testing constructor remains `internal`.
- Default `PeerClock()` now requires explicit awareness: v0.4.0 defaults to `.mesh`, which is wire-compat with v0.2.x. Migrating to star requires `PeerClock(topology: .star(role: .auto))`.
- **Renamed** `PeerClock.connectionEvents` (previously `AsyncStream<HeartbeatMonitor.Event>`) to `PeerClock.heartbeatEvents`. The `connectionEvents` name now exposes the new `AsyncStream<ConnectionEvent>` described above. Affects any downstream consumer observing heartbeat state transitions (none known outside the Examples demo).

### Deprecated

- The v0.3.0 tag is left in place but the release page will be marked "Superseded by v0.4.0 — do not use".

## [0.3.0-alpha.3] — 2026-04-15

**Star topology transport** for 1+N device sync, replacing full mesh. Designed for 10-device music recording sessions where one device naturally serves as control hub.

**Branch:** `feat/v0.3-star-transport`
**Status:** Alpha — API may change before 0.3.0 release. Backwards-incompatible with 0.2.x.

### Added — Plan A (Foundation)

- **`StarTransport`** — Public facade conforming to existing `Transport` protocol. Role-aware delegation to `StarHost` or `StarClient` via `promoteToHost()` / `demoteToClient()`.
- **`StarHost`** — `NWListener` server with per-client `ClientSession` instances. RFC 6455 §4.1 handshake with proper `Sec-WebSocket-Accept`, control frames (close/ping/pong with correct opcodes), graceful slow-client disconnect, listener auto-restart.
- **`StarClient`** — `NWConnection` client with HTTP upgrade, accept-hash verification, exponential reconnect (max 5 attempts, 30s cap), `NWConnection.waiting` handling with 10s timeout.
- **`WebSocketFrame`** — Minimal RFC 6455 codec: text/binary/close/ping/pong opcodes, 16-bit and 64-bit extended length, masking with `SecRandomCopyBytes`. Hardened for RSV bits, oversized control frames (>125 bytes), and 64-bit length MSB validation.
- **`MessageDispatcher`** (actor) — Single unified priority queue: `ntp > critical > control > status > heartbeat`. NTP bypasses backpressure for timestamp precision. Critical never dropped. Status/heartbeat are latest-only. `isSlowClient(threshold:)` for host-side disconnect decisions.
- **`WebSocketHandshake`** — `Sec-WebSocket-Accept` SHA1+base64 computation per RFC 6455 §1.3.
- **`BonjourAdvertiser`** — `NWListener.service` wrapper publishing TXT records (`role`, `peer_id`, `term`, `score`, `version`).
- **`BonjourBrowser`** — `NWBrowser` wrapper streaming `[DiscoveredPeer]` updates with serial DispatchQueue thread safety.
- **`ControlMessage`** — Tagged-union JSON: sessionInit / startRecording / stopRecording / heartbeat / status / recordingAck.
- **`NtpMessage`** — Separate ping/pong types for timestamp-precision queue separation.

### Added — Plan B (Election)

- **`HostElection`** (actor) — Full state machine: `idle / discovering / candidacy / host(term:sessionGeneration:) / joining / joinFailed / hostLost / demoted`. Configurable `Timing` (discover period, candidacy jitter range, settle period, retry backoff).
- **`HostScore`** — Tuple-comparable struct with priority-ordered fields: `manualPin`, `incumbent`, `powerConnected`, `thermalOK`, `deviceTier`, `stablePeerID`. Smaller UUID wins on tie.
- **`HostScore.current(localPeerID:incumbent:manualPin:)`** — Auto-gathers device state via `UIDevice.batteryState`, `ProcessInfo.thermalState`, and `userInterfaceIdiom`.
- **`TermStore`** — Persistent monotonic max term in `UserDefaults` with NSLock thread safety. `update(observed:)` returns the new max atomically.
- **`HostFencing`** — Stale-leader rejection (`observedTerm < maxSeenTerm`) and force-demote on observing higher term while host (per spec §5.1).
- **Election Storm jitter** — 500-1000ms randomized candidacy timeout prevents simultaneous-start race.
- **Settle period** — 500ms debounce on Bonjour peer set changes.
- **Split-brain recovery** — Higher-term host wins on partition reconnect; loser auto-demotes to `discovering`.
- **`session_generation`** explicit increment responsibility (resets on new term, +1 on same-term re-issue).

### Added — Plan E (Validation hooks)

- **`PeerClockTestHooks`** (actor, `#if DEBUG`) — Fault injection: `dropOutgoingRate(Double)`, `partition(peerIDs: Set<UUID>)`, `killHost`. Used by tests and diagnostic UIs.
- **`os_signpost`** intervals — `HostElection.start()` and `NTPSyncEngine.collectMeasurements()` instrumented for Instruments timing analysis.

### Tests

- **30+ tests** for transport layer (frame codec error paths, handshake, dispatcher priorities, integration round-trip)
- **22 tests** for election (score tuple comparison, term persistence, fencing decisions, state transitions, integration with simulated peer injection)

### Breaking Changes

- `Transport` implementations are now actor or `@unchecked Sendable` based with stricter concurrency.
- `MultipeerTransport` and `WiFiTransport` (mesh) remain available but are no longer the recommended path for 5+ device deployments.
- `PeerClock.coordinator` semantics replaced by `HostElection` for star topology consumers.

## [0.2.0] — 2026-04-10

Full peer-equal coordination stack: clock sync, commands, status sharing,
event scheduling, heartbeat monitoring, and resilient transport with
automatic failover.

### Added

- **CommandRouter hardening** (Phase 3.7) — split internal streams by message category; attach command identity for deduplication
- **Sync guard & schedule API hardening** (Phase 3.6) — `SyncSnapshot` for atomic sync state reads; `schedule()` now throws on stale sync, low quality, or past deadlines; `PeerClockError` enum; reschedule pending events on drift jump
- **Dynamic sync interval backoff** (Phase 3.5) — `BackoffController` stages ([5, 10, 20, 30]s default); auto-reset on drift jump; `syncBackoffStages` / `syncBackoffPromoteAfter` configuration
- **FailoverTransport** (Phase 3c) — automatic WiFi → MultipeerConnectivity failover with state machine; `activeTransportLabel` on facade
- **MultipeerConnectivity transport** (Phase 3b) — `MultipeerTransport` with delegate scaffolding; `MultipeerPeerIDStore` for persistent MCPeerID; `MultipeerIdentity` helpers
- **Reconnection & coordinator re-election** (Phase 3a) — short-retry with last-in-win; heartbeat-driven election; `flushNow` on rejoin; `simulateDisconnect` / `simulateReconnect` on MockTransport
- **EventScheduler** (Phase 2b) — `schedule(atSyncedTime:)` with `ScheduledEventHandle`; drift-jump rescheduling; `SchedulerEvent` stream for clock-jump warnings
- **Status sharing** (Phase 2a) — `StatusRegistry` (push with debounce) + `StatusReceiver` (pull with generation-based dedup); `HeartbeatMonitor` with connected → degraded → disconnected state machine; reserved `pc.*` status keys; `connectionEvents` stream on facade
- **Demo app** — iOS SwiftUI dashboard with transport toggle, schedule button, per-peer status display

## [0.1.0] — 2026-04-07

Initial release of the peer-equal clock synchronization library.

### Added

- Peer-equal architecture — no master/slave; coordinator auto-elected by smallest PeerID, invisible to application code
- `Transport` protocol with reliable + unreliable channels
- `WiFiTransport` — Network.framework (UDP + TCP) with Bonjour discovery
- `MockTransport` — in-memory transport for deterministic unit testing
- `NTPSyncEngine` — 4-timestamp exchange, 40 measurements at 30ms intervals, best-half filtering (fastest 50% by RTT)
- `DriftMonitor` — offset jump detection (>10ms triggers full re-sync)
- `CoordinatorElection` — automatic smallest-PeerID selection with re-election on disconnect
- `CommandRouter` — generic send / broadcast command channel
- `MessageCodec` — binary wire protocol (5-byte header + payload)
- `PeerClock` facade — role-free public API (`start`, `stop`, `now`, `peers`, `commands`, `broadcast`, `send`)
- `PeerClockCLI` — macOS CLI for verification
- Swift 6.0 strict concurrency throughout

[0.2.0]: https://github.com/hakaru/PeerClock/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hakaru/PeerClock/releases/tag/v0.1.0
