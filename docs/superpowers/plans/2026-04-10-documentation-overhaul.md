# PeerClock Documentation Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring all project documentation to OSS-publication quality: CHANGELOG, README update, docs reorganization, ARCHITECTURE.md, DocC comments on all public API, and CONTRIBUTING.md.

**Architecture:** Six independent documentation tasks that can largely run in parallel. No code logic changes — documentation and file moves only. All new docs in English.

**Tech Stack:** Markdown, Swift DocC comments, git

**Key principle:** All existing Japanese inline comments in source files stay as-is unless they are on a `public` symbol. Public API DocC comments are replaced with English equivalents. Internal/private comments are untouched.

---

## File Structure

### New files
- `CHANGELOG.md` — Keep a Changelog format
- `docs/ARCHITECTURE.md` — public-facing architecture overview
- `CONTRIBUTING.md` — contributor guide
- `docs/archive/DESIGN-v1.md` — moved from `docs/DESIGN.md`
- `docs/archive/PHASE1-plan.md` — moved from `docs/PHASE1.md`

### Modified files
- `README.md` — feature list, API examples, roadmap, architecture diagram update
- `Sources/PeerClock/PeerClock.swift` — DocC comments on all public symbols
- `Sources/PeerClock/Configuration.swift` — DocC comments on all public symbols
- `Sources/PeerClock/Types.swift` — DocC comments on all public symbols
- `Sources/PeerClock/PeerClockError.swift` — DocC comments
- `Sources/PeerClock/SyncSnapshot.swift` — DocC comments
- `Sources/PeerClock/Transport/Transport.swift` — DocC comments
- `Sources/PeerClock/Protocols/SyncEngine.swift` — DocC comments
- `Sources/PeerClock/Protocols/CommandHandler.swift` — DocC comments
- `Sources/PeerClock/EventScheduler/EventScheduler.swift` — DocC comments
- `Sources/PeerClock/EventScheduler/SchedulerTypes.swift` — DocC comments
- `Sources/PeerClock/Status/StatusRegistry.swift` — DocC comments
- `Sources/PeerClock/Status/StatusReceiver.swift` — DocC comments on public types
- `Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift` — DocC comments
- `Sources/PeerClock/Status/StatusKeys.swift` — DocC comments if public
- `Sources/PeerClock/Core/PeerID.swift` — DocC comments if public

---

### Task 1: Create CHANGELOG.md

**Files:**
- Create: `CHANGELOG.md`

- [ ] **Step 1: Create CHANGELOG.md**

```markdown
# Changelog

All notable changes to PeerClock are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.2.0] — 2026-04-10

Full peer-equal coordination stack: clock sync, commands, status sharing,
event scheduling, heartbeat monitoring, and resilient transport with
automatic failover.

### Added

- **CommandRouter hardening** (Phase 3.7) — split internal streams by
  message category; attach command identity for deduplication
- **Sync guard & schedule API hardening** (Phase 3.6) — `SyncSnapshot`
  for atomic sync state reads; `schedule()` now throws on stale sync,
  low quality, or past deadlines; `PeerClockError` enum; reschedule
  pending events on drift jump
- **Dynamic sync interval backoff** (Phase 3.5) — `BackoffController`
  stages ([5, 10, 20, 30]s default); auto-reset on drift jump;
  `syncBackoffStages` / `syncBackoffPromoteAfter` configuration
- **FailoverTransport** (Phase 3c) — automatic WiFi → MultipeerConnectivity
  failover with state machine; `activeTransportLabel` on facade
- **MultipeerConnectivity transport** (Phase 3b) — `MultipeerTransport`
  with delegate scaffolding; `MultipeerPeerIDStore` for persistent
  MCPeerID; `MultipeerIdentity` helpers
- **Reconnection & coordinator re-election** (Phase 3a) — short-retry
  with last-in-win; heartbeat-driven election; `flushNow` on rejoin;
  `simulateDisconnect` / `simulateReconnect` on MockTransport
- **EventScheduler** (Phase 2b) — `schedule(atSyncedTime:)` with
  `ScheduledEventHandle`; drift-jump rescheduling; `SchedulerEvent`
  stream for clock-jump warnings
- **Status sharing** (Phase 2a) — `StatusRegistry` (push with debounce) +
  `StatusReceiver` (pull with generation-based dedup); `HeartbeatMonitor`
  with connected → degraded → disconnected state machine; reserved
  `pc.*` status keys; `connectionEvents` stream on facade
- **Demo app** — iOS SwiftUI dashboard with transport toggle, schedule
  button, per-peer status display

## [0.1.0] — 2026-04-07

Initial release of the peer-equal clock synchronization library.

### Added

- Peer-equal architecture — no master/slave; coordinator auto-elected
  by smallest PeerID, invisible to application code
- `Transport` protocol with reliable + unreliable channels
- `WiFiTransport` — Network.framework (UDP + TCP) with Bonjour discovery
- `MockTransport` — in-memory transport for deterministic unit testing
- `NTPSyncEngine` — 4-timestamp exchange, 40 measurements at 30ms
  intervals, best-half filtering (fastest 50% by RTT)
- `DriftMonitor` — offset jump detection (>10ms triggers full re-sync)
- `CoordinatorElection` — automatic smallest-PeerID selection with
  re-election on disconnect
- `CommandRouter` — generic send / broadcast command channel
- `MessageCodec` — binary wire protocol (5-byte header + payload)
- `PeerClock` facade — role-free public API (`start`, `stop`, `now`,
  `peers`, `commands`, `broadcast`, `send`)
- `PeerClockCLI` — macOS CLI for verification
- Swift 6.0 strict concurrency throughout

[0.2.0]: https://github.com/hakaru/PeerClock/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hakaru/PeerClock/releases/tag/v0.1.0
```

- [ ] **Step 2: Verify the file renders correctly**

Run: `head -20 CHANGELOG.md`
Expected: First 20 lines of the changelog displayed correctly.

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git commit -m "docs: add CHANGELOG.md (v0.1.0 and v0.2.0)"
```

---

### Task 2: Update README.md

**Files:**
- Modify: `README.md`

The README needs these updates:
1. Add shields/badges (Swift 6.0, platforms, license, version)
2. Update the feature comparison table to show completed Phase 2-3 features
3. Add expanded API examples for Status, EventScheduler, HeartbeatMonitor, FailoverTransport
4. Update Architecture diagram to include all current components
5. Update Roadmap to reflect Phase 1-3.7 as completed
6. Add "Testing" section showing MockTransport injection
7. Link to ARCHITECTURE.md, CHANGELOG.md, CONTRIBUTING.md

- [ ] **Step 1: Rewrite README.md**

Replace the full content with the updated version. Key sections:

**Badges:**
```markdown
![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)
```

**Updated comparison table** — add Status sharing ✓, Event scheduling ✓, Heartbeat ✓, Transport failover ✓ columns.

**Updated Architecture diagram:**
```
PeerClock (Facade — all peers equal, no roles)
│
├── Transport          Protocol: reliable + unreliable channels
│   ├── WiFiTransport  Network.framework (UDP + TCP)
│   ├── MultipeerTransport  MultipeerConnectivity fallback
│   ├── FailoverTransport   Auto WiFi → MPC failover
│   └── MockTransport  In-memory (for testing)
│
├── Coordination       Auto coordinator election (smallest PeerID)
│                      Transparent to app — no API exposure
│
├── ClockSync          NTP-inspired 4-timestamp exchange
│   ├── NTPSyncEngine  40 measurements, best-half filtering
│   ├── DriftMonitor   Jump detection (>10ms → full re-sync)
│   └── BackoffController  Dynamic sync interval [5→30s]
│
├── Command            Generic command send/broadcast
│   └── CommandRouter  App defines semantics, PeerClock routes
│
├── Status             Peer status sharing
│   ├── StatusRegistry   Local status (push with debounce)
│   └── StatusReceiver   Remote status (generation-based dedup)
│
├── Heartbeat          Connection health monitoring
│   └── HeartbeatMonitor  connected → degraded → disconnected
│
├── EventScheduler     Synchronized precision event firing
│                      mach_absolute_time + sync offset
│
└── Wire               Binary protocol (5-byte header + payload)
    └── MessageCodec   Encode/decode, transport-agnostic
```

**New API examples** — add after existing basic example:

```swift
// Status sharing
await clock.setStatus("recording", forKey: "app.state")
for await status in clock.statusUpdates {
    let entries = status.entries
    // decode app-defined values from entries
}

// Connection health
for await event in clock.connectionEvents {
    print("\(event.peerID): \(event.state)")  // .connected / .degraded / .disconnected
}

// Precision event scheduling
let fireTime = clock.now + 3_000_000_000  // 3 seconds from now
let handle = try await clock.schedule(atSyncedTime: fireTime) {
    // Fires simultaneously on all devices ±2ms
    startRecording()
}
// handle.cancel() to abort
```

**Updated Roadmap** — Phase 1–3.7 all checked, Phase 4 remains.

**New footer links:**
```markdown
## Documentation

- [Architecture](docs/ARCHITECTURE.md) — component design, wire protocol, sync algorithm details
- [Changelog](CHANGELOG.md) — release history
- [Contributing](CONTRIBUTING.md) — how to build, test, and submit changes
```

- [ ] **Step 2: Verify rendering**

Run: `swift build 2>&1 | tail -5`
Expected: Build succeeds (ensures no syntax issues in doc comments referenced from README).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README with completed Phase 2-3 features, expanded API examples, and new docs links"
```

---

### Task 3: Reorganize docs/ directory

**Files:**
- Create: `docs/archive/` directory
- Move: `docs/DESIGN.md` → `docs/archive/DESIGN-v1.md`
- Move: `docs/PHASE1.md` → `docs/archive/PHASE1-plan.md`

- [ ] **Step 1: Create archive directory and move files**

```bash
mkdir -p docs/archive
git mv docs/DESIGN.md docs/archive/DESIGN-v1.md
git mv docs/PHASE1.md docs/archive/PHASE1-plan.md
```

- [ ] **Step 2: Add archive notice to DESIGN-v1.md**

Prepend to the top of `docs/archive/DESIGN-v1.md`:

```markdown
> **⚠️ Archived:** This is the original v1 design document (master/slave architecture).
> PeerClock was redesigned to a peer-equal architecture in April 2026.
> The current design is documented in [ARCHITECTURE.md](../ARCHITECTURE.md)
> and [the v2 design spec](../superpowers/specs/2026-04-07-peerclock-v2-design.md).

```

- [ ] **Step 3: Add archive notice to PHASE1-plan.md**

Prepend to the top of `docs/archive/PHASE1-plan.md`:

```markdown
> **⚠️ Archived:** This was the Phase 1 implementation plan. Phase 1 shipped as v0.1.0
> on 2026-04-07. See [CHANGELOG.md](../../CHANGELOG.md) for the release summary.

```

- [ ] **Step 4: Update CLAUDE.md reference**

In `CLAUDE.md`, update the line referencing `docs/DESIGN.md`:

Old: `- `docs/DESIGN.md` は初期設計（master/slave）で参考情報。正の設計仕様は `docs/superpowers/specs/` の v2 spec`
New: `- `docs/archive/DESIGN-v1.md` は初期設計（master/slave）のアーカイブ。正の設計仕様は `docs/superpowers/specs/` の v2 spec`

- [ ] **Step 5: Commit**

```bash
git add docs/archive/ CLAUDE.md
git commit -m "docs: archive legacy DESIGN.md and PHASE1.md"
```

---

### Task 4: Create ARCHITECTURE.md

**Files:**
- Create: `docs/ARCHITECTURE.md`

This is the public-facing English architecture document, distilled from the internal v2 spec. It should cover:

- [ ] **Step 1: Write docs/ARCHITECTURE.md**

```markdown
# PeerClock Architecture

## Design Principles

- **All nodes are equal.** The public API has no role concept. Any device
  can send commands, share status, and schedule events.
- **Transparent coordinator.** Clock synchronization requires a single
  time reference. PeerClock auto-elects the peer with the smallest
  `PeerID` (UUID). The app never sees this.
- **Infrastructure only.** PeerClock routes commands and status — it does
  not define their semantics. Your app decides what
  `"com.myapp.record.start"` means.
- **Protocol at every boundary.** `Transport`, `SyncEngine`, and
  `CommandHandler` are protocols with immediate concrete
  implementations. `MockTransport` (in-memory) enables deterministic
  unit testing; `WiFiTransport` and `MultipeerTransport` run on
  real networks.

## Component Overview

```
PeerClock (Public Facade)
│
├── Transport/
│   ├── Transport          Protocol: reliable + unreliable channels
│   ├── WiFiTransport      Network.framework — UDP (sync) + TCP (commands)
│   ├── MultipeerTransport MultipeerConnectivity — Bluetooth/Wi-Fi Direct
│   ├── FailoverTransport  Wraps WiFi + MPC with auto-switch state machine
│   ├── MockTransport      In-memory — deterministic tests, simulated latency
│   └── Discovery          Bonjour: all nodes browse + advertise _peerclock._udp
│
├── Coordination/
│   └── CoordinatorElection  Smallest PeerID wins; re-election on disconnect
│
├── ClockSync/
│   ├── NTPSyncEngine      4-timestamp exchange + best-half filtering
│   ├── DriftMonitor        Offset jump detection → full re-sync trigger
│   └── BackoffController   Dynamic sync interval: [5, 10, 20, 30]s stages
│
├── Command/
│   └── CommandRouter      Send/broadcast with stream-split by message category
│
├── Status/
│   ├── StatusRegistry     Local status: debounced push broadcast
│   ├── StatusReceiver     Remote status: generation-based dedup + debounce
│   └── StatusKeys         Reserved `pc.*` key constants
│
├── Heartbeat/
│   └── HeartbeatMonitor   connected → degraded → disconnected state machine
│
├── EventScheduler/
│   ├── EventScheduler     mach_absolute_time precision firing
│   └── SchedulerTypes     ScheduledEventHandle, ScheduledEventState, SchedulerEvent
│
└── Wire/
    ├── MessageCodec       Encode / decode all message types
    ├── Message            Enum of all wire message cases
    └── StatusEntry        Key-value entry for STATUS_PUSH payloads
```

## Wire Protocol

Every message has a 5-byte header followed by a variable-length payload:

```
┌──────────┬──────────┬──────────┬──────────────┐
│ Version  │ Category │ Flags    │ Length       │
│ 1 byte   │ 1 byte   │ 1 byte   │ 2 bytes BE  │
└──────────┴──────────┴──────────┴──────────────┘
```

- **Version:** Protocol version (currently `1`).
- **Category:** Message type identifier.
- **Flags:** Reserved (currently `0x00`).
- **Length:** Big-endian `UInt16` — byte count of the payload.

### Message Categories

| Category | Hex  | Channel     | Direction | Description |
|----------|------|-------------|-----------|-------------|
| SYNC_REQUEST | 0x01 | Unreliable | Any → Coordinator | Clock sync ping (carries t0) |
| SYNC_RESPONSE | 0x02 | Unreliable | Coordinator → Any | Clock sync pong (carries t0, t1, t2) |
| HEARTBEAT | 0x10 | Unreliable | Broadcast | Liveness signal |
| DISCONNECT | 0x11 | Reliable | Unicast | Graceful leave notification |
| ELECTION | 0x12 | Reliable | Broadcast | Coordinator election message |
| APP_COMMAND | 0x20 | Reliable | Unicast / Broadcast | Application-defined command |
| STATUS_PUSH | 0x30 | Reliable | Broadcast | Local status snapshot |
| STATUS_REQUEST | 0x31 | Reliable | Unicast | Pull request for peer status |
| STATUS_RESPONSE | 0x32 | Reliable | Unicast | Response to STATUS_REQUEST |

All integers are big-endian. Strings are UTF-8. Timestamps are
`UInt64` nanoseconds based on `mach_continuous_time`.

## Clock Synchronization

### Algorithm

PeerClock uses an NTP-inspired 4-timestamp exchange:

```
Peer A (follower)          Peer B (coordinator)
    │                            │
    │── SYNC_REQUEST [t0] ──────>│
    │                      t1 = receive time
    │                      t2 = send time
    │<── SYNC_RESPONSE [t0,t1,t2]│
    │ t3 = receive time          │
    │                            │
    offset = ((t1 - t0) + (t2 - t3)) / 2
    RTT    = (t3 - t0) - (t2 - t1)
```

### Filtering

1. Collect 40 measurements at 30ms intervals (~1.2s total)
2. Sort by round-trip delay (ascending)
3. Keep only the fastest 50% (best-half filtering)
4. Compute mean offset from the filtered set

### Maintenance

- **Backoff stages:** After initial sync, re-sync interval starts at 5s
  and progressively extends to 10s → 20s → 30s as sync quality remains
  stable. Promotion requires 3 consecutive successful rounds at each stage.
- **Jump detection:** If the offset changes by more than 10ms between
  rounds, `DriftMonitor` triggers a full re-sync and resets the backoff
  to stage 0.

### Precision Budget

| Source | Raw Error | Mitigation | Residual |
|--------|-----------|------------|----------|
| Wi-Fi UDP jitter | 1–10ms | Best-half filtering | ~1–2ms |
| Crystal oscillator drift | 50ppm (0.25ms/5s) | Periodic re-sync | <0.25ms |
| iOS scheduling | <1ms | `mach_continuous_time` | <1ms |
| **Total** | | | **±2ms typical** |

## Transport Failover

`FailoverTransport` wraps `WiFiTransport` and `MultipeerTransport`:

```
           ┌─────────────────┐
           │ FailoverTransport│
           │  (state machine) │
           └────┬────────┬───┘
                │        │
       ┌────────▼─┐  ┌───▼──────────┐
       │WiFiTransport│  │MultipeerTransport│
       │  (primary)  │  │  (fallback)     │
       └─────────────┘  └────────────────┘
```

1. Start with `WiFiTransport`
2. If WiFi fails (start error or connection loss), switch to `MultipeerTransport`
3. Periodically probe WiFi; switch back when available
4. `activeTransportLabel` exposes which transport is currently in use

## Testing Strategy

All deterministic logic is tested via `MockTransport` — an in-memory
transport that simulates peer connections without real networking:

```swift
let network = MockNetwork()
let clock = PeerClock(configuration: config, transportFactory: { peerID in
    network.createTransport(for: peerID)
})
```

`MockTransport` supports:
- Simulated latency and jitter
- `simulateDisconnect()` / `simulateReconnect()` for resilience tests
- Separate tracking of reliable vs. unreliable broadcasts

Integration tests on physical devices verify real-network behavior.

Current test suite: **127 tests across 26 suites**, all passing.

## Extension Points

### Custom Transport

Implement the `Transport` protocol to add your own networking layer:

```swift
public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }
    func send(_ data: Data, to peer: PeerID) async throws
    func broadcast(_ data: Data) async throws
    func broadcastUnreliable(_ data: Data) async throws
}
```

Inject it via the `transportFactory` parameter:

```swift
let clock = PeerClock(transportFactory: { peerID in
    MyCustomTransport(peerID: peerID)
})
```

### Application Commands

PeerClock is command-agnostic. Define your own command types:

```swift
let command = Command(type: "com.myapp.record.start", payload: config.encoded())
try await clock.broadcast(command)
```

### Custom Status Keys

Reserved keys use the `pc.*` prefix. Your app can define any other key:

```swift
await clock.setStatus("recording", forKey: "app.state")
await clock.setStatus(batteryInfo, forKey: "app.battery")
```
```

- [ ] **Step 2: Verify file renders**

Run: `wc -l docs/ARCHITECTURE.md`
Expected: ~200 lines.

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md
git commit -m "docs: add ARCHITECTURE.md (public-facing architecture overview)"
```

---

### Task 5: Add DocC comments to all public API

**Files:**
- Modify: `Sources/PeerClock/PeerClock.swift`
- Modify: `Sources/PeerClock/Configuration.swift`
- Modify: `Sources/PeerClock/Types.swift`
- Modify: `Sources/PeerClock/PeerClockError.swift`
- Modify: `Sources/PeerClock/SyncSnapshot.swift`
- Modify: `Sources/PeerClock/Transport/Transport.swift`
- Modify: `Sources/PeerClock/Protocols/SyncEngine.swift`
- Modify: `Sources/PeerClock/Protocols/CommandHandler.swift`
- Modify: `Sources/PeerClock/EventScheduler/EventScheduler.swift`
- Modify: `Sources/PeerClock/EventScheduler/SchedulerTypes.swift`
- Modify: `Sources/PeerClock/Status/StatusRegistry.swift`
- Modify: `Sources/PeerClock/Status/StatusReceiver.swift`
- Modify: `Sources/PeerClock/Heartbeat/HeartbeatMonitor.swift`
- Modify: `Sources/PeerClock/Status/StatusKeys.swift`
- Modify: `Sources/PeerClock/Core/PeerID.swift`

Rules:
- Replace Japanese `///` comments on **public** symbols with English DocC
- Add `- Parameter`, `- Returns`, `- Throws` where applicable
- Do NOT touch private/internal comments
- Do NOT add comments to symbols that already have adequate English docs
- Keep comments concise — one sentence for simple properties, structured docs for complex methods

- [ ] **Step 1: Update PeerClock.swift (facade)**

Replace all Japanese `///` on public symbols with English equivalents. Key changes:

```swift
/// Facade that integrates all PeerClock components.
///
/// Every peer runs the same code — there are no roles. An internal coordinator
/// is auto-elected transparently for clock synchronization.
///
/// ## Quick Start
///
/// ```swift
/// let clock = PeerClock()
/// try await clock.start()
/// let timestamp = clock.now  // synchronized across all peers ±2ms
/// ```
public final class PeerClock: @unchecked Sendable {

    /// Library version string (SemVer).
    public static let version = "0.2.0"

    /// Unique identifier for this peer, generated at init.
    public let localPeerID: PeerID

    /// Stream of synchronization state changes.
    public let syncState: AsyncStream<SyncState>

    /// Stream of discovered peers on the local network.
    public let peers: AsyncStream<[Peer]>

    /// Stream of incoming application commands from remote peers.
    public var commands: AsyncStream<(PeerID, Command)> { ... }

    /// Current synchronized time in nanoseconds.
    ///
    /// Applies the clock offset from the sync engine to the local
    /// monotonic clock. Agrees across all synced peers within ±2ms.
    public var now: UInt64 { ... }

    /// The auto-elected sync coordinator's peer ID, or `nil` if not yet elected.
    ///
    /// Exposed for debugging and visualization only — application logic
    /// should not depend on which peer is the coordinator.
    public var coordinatorID: PeerID? { ... }

    /// Atomic snapshot of the current synchronization state.
    ///
    /// Use for sync-guard checks before scheduling or for UI display.
    public var currentSync: SyncSnapshot { ... }

    /// Label of the currently active transport when using `FailoverTransport`.
    ///
    /// Returns `nil` when not using `FailoverTransport`.
    public var activeTransportLabel: String? { ... }

    /// Creates a new PeerClock instance.
    ///
    /// - Parameters:
    ///   - configuration: Runtime parameters. Defaults to ``Configuration/default``.
    ///   - transportFactory: Optional factory closure for custom or mock transports.
    ///     When `nil`, ``WiFiTransport`` is used.
    public init(
        configuration: Configuration = .default,
        transportFactory: (@Sendable (PeerID) -> any Transport)? = nil
    ) { ... }

    /// Starts peer discovery and clock synchronization.
    ///
    /// Call this once after init. Begins Bonjour advertising/browsing,
    /// coordinator election, and the sync loop.
    ///
    /// - Throws: Transport-level errors (e.g., network permission denied).
    public func start() async throws { ... }

    /// Stops synchronization and disconnects from all peers.
    public func stop() async { ... }

    /// Sends a command to a specific peer.
    ///
    /// - Parameters:
    ///   - command: The command to send.
    ///   - peer: Target peer identifier.
    public func send(_ command: Command, to peer: PeerID) async throws { ... }

    /// Broadcasts a command to all connected peers.
    ///
    /// - Parameter command: The command to broadcast.
    public func broadcast(_ command: Command) async throws { ... }

    /// Sets a raw `Data` status value for the given key.
    ///
    /// Status updates are debounced and broadcast to all peers.
    /// Use the generic ``setStatus(_:forKey:)-swift.method`` overload
    /// for `Codable` values.
    ///
    /// - Parameters:
    ///   - data: Raw bytes to store.
    ///   - key: Status key. Use `pc.*` prefix for reserved keys.
    public func setStatus(_ data: Data, forKey key: String) async { ... }

    /// Sets a `Codable` status value for the given key.
    ///
    /// - Parameters:
    ///   - value: The value to encode and store.
    ///   - key: Status key.
    /// - Throws: Encoding error if `value` cannot be serialized.
    public func setStatus<T: Codable & Sendable>(_ value: T, forKey key: String) async throws { ... }

    /// Returns the latest known status of a remote peer, or `nil` if unknown.
    ///
    /// - Parameter peer: The peer to query.
    /// - Returns: The most recent status snapshot, or `nil`.
    public func status(of peer: PeerID) async -> RemotePeerStatus? { ... }

    /// Stream of debounced remote status updates.
    public var statusUpdates: AsyncStream<RemotePeerStatus> { ... }

    /// Returns the heartbeat-derived connection state of a peer.
    ///
    /// - Parameter peer: The peer to query.
    /// - Returns: Connection state, or `nil` if the peer is unknown.
    public func connectionState(of peer: PeerID) async -> ConnectionState? { ... }

    /// Stream of heartbeat connection state transitions.
    public var connectionEvents: AsyncStream<HeartbeatMonitor.Event> { ... }

    /// Schedules an action to fire at a synchronized time across all peers.
    ///
    /// Guards are applied in this order:
    /// 1. PeerClock not started → ``PeerClockError/notStarted``
    /// 2. Not synchronized or sync stale → ``PeerClockError/notSynchronized``
    /// 3. Quality below threshold → ``PeerClockError/qualityBelowThreshold(quality:threshold:)``
    /// 4. Past deadline exceeds tolerance → ``PeerClockError/deadlineExceeded(lateBy:tolerance:)``
    ///
    /// - Parameters:
    ///   - atSyncedTime: Target fire time in the `clock.now` time axis (nanoseconds).
    ///   - lateTolerance: Maximum acceptable lateness for past-time scheduling.
    ///     Defaults to `.zero` (reject any past time).
    ///   - action: The closure to execute at the scheduled time.
    /// - Returns: A handle that can cancel or query the scheduled event.
    /// - Throws: ``PeerClockError`` if any guard fails.
    public func schedule(
        atSyncedTime: UInt64,
        lateTolerance: Duration = .zero,
        _ action: @Sendable @escaping () -> Void
    ) async throws -> ScheduledEventHandle { ... }

    /// Stream of scheduler notifications (e.g., drift-jump warnings).
    public var schedulerEvents: AsyncStream<SchedulerEvent> { ... }
}
```

- [ ] **Step 2: Update PeerClockError.swift**

```swift
/// Errors thrown by the PeerClock public API.
public enum PeerClockError: Error, Sendable, Equatable {
    /// `start()` has not been called yet.
    case notStarted

    /// Clock is not synchronized, or the last sync is older than
    /// `Configuration.syncStaleAfter`.
    case notSynchronized

    /// Sync confidence is below `Configuration.minSyncQuality`.
    ///
    /// - Parameters:
    ///   - quality: The current confidence value.
    ///   - threshold: The configured minimum threshold.
    case qualityBelowThreshold(quality: Double, threshold: Double)

    /// The requested schedule time has already passed beyond the
    /// allowed tolerance.
    ///
    /// - Parameters:
    ///   - lateBy: How far past the target time.
    ///   - tolerance: The maximum lateness that was allowed.
    case deadlineExceeded(lateBy: Duration, tolerance: Duration)
}
```

- [ ] **Step 3: Update SyncSnapshot.swift**

```swift
/// Atomic snapshot of PeerClock's synchronization state.
///
/// Obtain via ``PeerClock/currentSync``. Use ``isSynchronized`` to check
/// both sync state and freshness before scheduling events.
public struct SyncSnapshot: Sendable {
    /// The most recent sync lifecycle state.
    public let state: SyncState
    /// Current clock offset in seconds (0 when not synchronized).
    public let offset: TimeInterval
    /// Quality metrics from the last sync round, or `nil` if not yet synced.
    public let quality: SyncQuality?
    /// Monotonic timestamp (ns) of the last `.synced` transition, or `nil`.
    public let lastSyncedAt: UInt64?
    /// Monotonic timestamp (ns) when this snapshot was captured.
    public let capturedAt: UInt64

    /// `true` when synced **and** the last sync is within `Configuration.syncStaleAfter`.
    public var isSynchronized: Bool { ... }
}
```

- [ ] **Step 4: Update Transport.swift protocol**

```swift
/// Abstraction over the network transport layer.
///
/// PeerClock ships with three implementations:
/// - ``WiFiTransport``: Network.framework (UDP + TCP) with Bonjour discovery
/// - ``MultipeerTransport``: MultipeerConnectivity fallback
/// - ``MockTransport``: In-memory transport for deterministic testing
///
/// Implement this protocol to add custom transports.
public protocol Transport: Sendable {
    /// Starts listening and advertising on the network.
    func start() async throws
    /// Stops all network activity and disconnects peers.
    func stop() async
    /// Stream of currently connected peer ID sets.
    var peers: AsyncStream<Set<PeerID>> { get }
    /// Stream of incoming raw messages from peers.
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }
    /// Sends data reliably to a specific peer.
    func send(_ data: Data, to peer: PeerID) async throws
    /// Broadcasts data reliably to all connected peers.
    func broadcast(_ data: Data) async throws
    /// Broadcasts data via the unreliable (UDP) channel.
    ///
    /// Used for latency-sensitive, loss-tolerant traffic like heartbeats.
    /// Default implementation falls back to ``broadcast(_:)``.
    func broadcastUnreliable(_ data: Data) async throws
}
```

- [ ] **Step 5: Update SyncEngine.swift protocol**

```swift
/// Protocol for clock synchronization engines.
///
/// ``NTPSyncEngine`` is the built-in implementation using NTP-style
/// 4-timestamp exchange with best-half filtering.
public protocol SyncEngine: Sendable {
    /// Current clock offset relative to the coordinator, in seconds.
    var currentOffset: TimeInterval { get }
    /// Starts synchronizing against the given coordinator peer.
    func start(coordinator: PeerID) async
    /// Stops synchronization.
    func stop() async
    /// Stream of sync state changes during the sync lifecycle.
    var syncStateUpdates: AsyncStream<SyncState> { get }
}
```

- [ ] **Step 6: Update CommandHandler.swift protocol**

```swift
/// Protocol for the command routing layer.
///
/// ``CommandRouter`` is the built-in implementation that handles
/// send, broadcast, and incoming command streams.
public protocol CommandHandler: Sendable {
    /// Sends a command to a specific peer.
    func send(_ command: Command, to peer: PeerID) async throws
    /// Broadcasts a command to all connected peers.
    func broadcast(_ command: Command) async throws
    /// Stream of incoming commands from remote peers.
    var incomingCommands: AsyncStream<(PeerID, Command)> { get }
}
```

- [ ] **Step 7: Update SchedulerTypes.swift**

```swift
/// Lifecycle state of a scheduled event.
public enum ScheduledEventState: Sendable, Equatable {
    /// Waiting to fire.
    case pending
    /// Fired on time (action executed).
    case fired
    /// Cancelled before firing (action was not executed).
    case cancelled
    /// Fired late due to past-time scheduling or wake-up delay (action was executed).
    case missed
}

/// Notification events emitted by ``EventScheduler``.
public enum SchedulerEvent: Sendable, Equatable {
    /// A clock-drift jump was detected while an event was pending.
    ///
    /// The event fires at its original time — the app can use this
    /// notification to apply post-hoc timestamp corrections.
    ///
    /// - Parameters:
    ///   - eventID: The affected scheduled event.
    ///   - oldOffsetNs: Clock offset before the jump (nanoseconds).
    ///   - newOffsetNs: Clock offset after the jump (nanoseconds).
    case driftWarning(eventID: UUID, oldOffsetNs: Int64, newOffsetNs: Int64)
}

/// Handle returned after scheduling an event.
///
/// Holds only a UUID and a weak reference to the scheduler.
/// The scheduler owns the action and firing task.
public struct ScheduledEventHandle: Sendable, Hashable {
    /// Unique identifier for the scheduled event.
    public let id: UUID

    /// Cancels this event. No-op if already fired or cancelled.
    public func cancel() async { ... }

    /// Returns the current state of this event.
    public func state() async -> ScheduledEventState { ... }
}
```

- [ ] **Step 8: Update Configuration.swift**

Add English docs for the remaining undocumented public properties:

```swift
/// MultipeerConnectivity service type identifier.
public var mcServiceType: String

/// Maximum number of peers for MultipeerConnectivity sessions.
public var mcMaxPeers: Int

/// Retry interval in seconds for transport-level reconnection attempts.
public let reconnectRetryInterval: TimeInterval

/// Maximum number of transport-level reconnection attempts before giving up.
public let reconnectMaxAttempts: Int

/// Backoff stages in seconds for sync interval progression.
///
/// After initial sync, the interval starts at the first stage and
/// advances to the next after ``syncBackoffPromoteAfter`` consecutive
/// successful rounds. Resets to stage 0 on drift jump.
public let syncBackoffStages: [TimeInterval]

/// Number of consecutive successful sync rounds required to advance
/// to the next backoff stage.
public let syncBackoffPromoteAfter: Int

/// Minimum sync confidence (0.0–1.0) required by ``PeerClock/schedule(atSyncedTime:lateTolerance:_:)``.
///
/// If `quality.confidence` falls below this threshold, scheduling throws
/// ``PeerClockError/qualityBelowThreshold(quality:threshold:)``.
public let minSyncQuality: Double

/// Maximum time since the last successful sync for ``SyncSnapshot/isSynchronized``
/// to return `true`. Default: 90 seconds.
public let syncStaleAfter: Duration
```

- [ ] **Step 9: Verify build**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

- [ ] **Step 10: Run tests**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 127 tests in 26 suites passed`

- [ ] **Step 11: Commit**

```bash
git add Sources/
git commit -m "docs: add English DocC comments to all public API symbols"
```

---

### Task 6: Create CONTRIBUTING.md

**Files:**
- Create: `CONTRIBUTING.md`

- [ ] **Step 1: Write CONTRIBUTING.md**

```markdown
# Contributing to PeerClock

Thanks for your interest in contributing! This guide covers how to build,
test, and submit changes.

## Prerequisites

- **Swift 6.0+** (Xcode 16+ or a compatible Swift toolchain)
- **macOS 14+** (Sonoma) for building
- Physical iOS 17+ devices for WiFi/MultipeerConnectivity integration tests

## Building

```bash
swift build
```

PeerClock is a Swift Package Manager project with no external dependencies.

## Running Tests

```bash
# All tests
swift test

# A specific test suite
swift test --filter NTPSyncEngineTests

# A single test
swift test --filter NTPSyncEngineTests/offsetCalculation
```

Tests use `MockTransport` (in-memory) — no network or devices required.

The test suite uses Swift Testing (`import Testing`, `@Suite`, `@Test`,
`#expect`), not XCTest.

## Project Structure

```
Sources/PeerClock/       Library source
Sources/PeerClockCLI/    macOS CLI tool
Tests/PeerClockTests/    Unit tests (MockTransport-based)
Examples/PeerClockDemo/  iOS SwiftUI demo app
docs/                    Architecture and design documents
```

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for component details.

## Code Style

- **Swift 6 strict concurrency** — all public types must be `Sendable`.
  Mutable classes use `@unchecked Sendable` + `NSLock`.
- **No external dependencies** — the library must remain dependency-free.
- **Protocol at every boundary** — new components should implement a
  protocol so they can be mocked in tests.

## Submitting Changes

1. Fork the repository and create a feature branch
2. Write tests first (TDD preferred)
3. Ensure all 127+ tests pass: `swift test`
4. Ensure the build succeeds with no warnings: `swift build`
5. Keep commits focused and conventional:
   - `feat:` new feature
   - `fix:` bug fix
   - `docs:` documentation only
   - `test:` test additions
   - `refactor:` code restructuring with no behavior change
6. Open a pull request against `main`

## Adding a New Transport

Implement the `Transport` protocol (see
[`Sources/PeerClock/Transport/Transport.swift`](Sources/PeerClock/Transport/Transport.swift)):

```swift
public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }
    func send(_ data: Data, to peer: PeerID) async throws
    func broadcast(_ data: Data) async throws
    func broadcastUnreliable(_ data: Data) async throws
}
```

Test it by injecting via `PeerClock(transportFactory:)`.

## Questions?

Open an issue at [github.com/hakaru/PeerClock/issues](https://github.com/hakaru/PeerClock/issues).
```

- [ ] **Step 2: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs: add CONTRIBUTING.md"
```

---

## Verification

After all tasks are complete:

- [ ] `swift build` succeeds
- [ ] `swift test` passes all 127 tests
- [ ] `README.md` links to `ARCHITECTURE.md`, `CHANGELOG.md`, `CONTRIBUTING.md` — all exist
- [ ] `docs/DESIGN.md` and `docs/PHASE1.md` no longer exist at old paths
- [ ] `docs/archive/DESIGN-v1.md` and `docs/archive/PHASE1-plan.md` exist with archive notices
- [ ] All public symbols in `Sources/PeerClock/` have English `///` DocC comments
- [ ] No private or internal comments were changed
