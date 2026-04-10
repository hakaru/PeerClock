# Changelog

All notable changes to PeerClock are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
