# PeerClock

![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange)
![iOS 17+](https://img.shields.io/badge/iOS-17%2B-blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![License: MIT](https://img.shields.io/badge/License-MIT-green)

Peer-equal P2P clock synchronization and device coordination for Apple devices.

## What is PeerClock?

PeerClock is a Swift library that synchronizes clocks and coordinates actions across multiple Apple devices on the same local network — **without an external server, without a master device**. Every device is an equal peer. Clocks agree within ~2ms, and a generic command channel lets apps coordinate anything.

## How is this different?

| | TrueTime / Kronos | PeerKit / sReto | **PeerClock** |
|--|-------------------|----------------|---------------|
| Sync target | External NTP server | N/A | Nearby devices (P2P) |
| Topology | Client → Server | Peer-to-peer | **Peer-equal** (auto coordinator) |
| Internet | Required | Not required | Not required |
| Clock sync | Yes | No | **Yes (±2ms)** |
| Command channel | No | Data transfer only | **Generic commands** |
| Status sharing | No | No | **Push + Pull** |
| Event scheduling | No | No | **Synchronized precision** |
| Heartbeat monitoring | No | No | **3-state (connected/degraded/disconnected)** |
| Transport failover | N/A | Manual | **Automatic (WiFi → MPC)** |

No existing Swift library combines peer-equal clock sync, generic commands, status sharing, event scheduling, and transport failover.

## Use Cases

- **Multi-device audio recording** — Start recording on multiple iPhones simultaneously with sample-accurate alignment
- **Multi-camera video capture** — Synchronize timecode across devices for post-production
- **Synchronized playback** — Play audio/video in perfect sync across devices
- **Device fleet management** — Monitor battery, storage, state across connected devices
- **Any P2P app** needing devices to agree on "now" and coordinate actions

## API

### Basic — Clock Sync & Commands

```swift
import PeerClock

// All devices run the same code — no role assignment
let clock = PeerClock()
try await clock.start()

// Wait for peers
for await peers in clock.peers {
    if peers.count >= 2 { break }
}

// Synchronized time (agrees across all devices ±2ms)
let timestamp = clock.now

// Send commands (semantics defined by your app)
try await clock.broadcast(
    Command(type: "com.myapp.record.start", payload: config.encoded())
)

// Receive commands
for await (sender, command) in clock.commands {
    handleCommand(command, from: sender)
}
```

### Status Sharing

```swift
// Publish local status (debounced, auto-broadcast)
await clock.setStatus("recording", forKey: "app.state")

// Observe remote peers' status
for await status in clock.statusUpdates {
    let entries = status.entries  // [String: Data]
    // Decode app-defined values
}
```

### Connection Health

```swift
// Monitor heartbeat-driven connection state
for await event in clock.connectionEvents {
    print("\(event.peerID): \(event.state)")
    // .connected → .degraded → .disconnected
}
```

### Precision Event Scheduling

```swift
// Schedule an action 3 seconds from now — fires on all devices ±2ms
let fireTime = clock.now + 3_000_000_000
let handle = try await clock.schedule(atSyncedTime: fireTime) {
    startRecording()
}

// Cancel if needed
await handle.cancel()
```

## Architecture

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

### Clock Synchronization

1. **Discovery** — All nodes browse + advertise via Bonjour
2. **Coordinator election** — Smallest PeerID becomes sync reference (automatic, invisible to app)
3. **4-timestamp exchange** — NTP-inspired: `offset = ((t1-t0) + (t2-t3)) / 2`
4. **Best-half filtering** — 40 measurements, sort by RTT, use fastest 50%
5. **Dynamic re-sync** — Backoff stages: 5s → 10s → 20s → 30s as quality stabilizes
6. **Jump detection** — Offset change >10ms triggers full re-sync and backoff reset

### Precision Budget

| Source | Error | Mitigation |
|--------|-------|------------|
| Wi-Fi UDP jitter | 1-10ms | Best-half filtering → ~1-2ms |
| Crystal oscillator drift | 50ppm = 0.25ms/5s | Periodic re-sync |
| iOS scheduling | <1ms | `mach_continuous_time` for sub-ms timing |
| **Total** | **±2ms typical** | |

## Requirements

- iOS 17.0+ / macOS 14+
- Swift 6.0+
- Same local Wi-Fi network

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/hakaru/PeerClock.git", from: "0.2.0")
]
```

## Testing

All deterministic logic is tested via `MockTransport` (in-memory, no network needed):

```swift
let network = MockNetwork()
let clock = PeerClock(configuration: config, transportFactory: { peerID in
    network.createTransport(for: peerID)
})
```

```bash
swift test                    # 127 tests, 26 suites
swift test --filter NTPSyncEngineTests  # single suite
```

## Roadmap

### Completed

- [x] **Phase 1** — Transport + ClockSync + Command + Coordinator election + Facade
- [x] **Phase 2a** — Status registry + HeartbeatMonitor (push/pull, generation counter, debounce)
- [x] **Phase 2b** — EventScheduler (mach_absolute_time precision firing)
- [x] **Phase 3a** — Reconnection + coordinator re-election
- [x] **Phase 3b** — MultipeerConnectivity transport
- [x] **Phase 3c** — FailoverTransport (automatic WiFi → MPC)
- [x] **Phase 3.5** — Dynamic sync interval backoff
- [x] **Phase 3.6** — Sync guard + schedule API hardening
- [x] **Phase 3.7** — CommandRouter hardening (stream split + command identity)

### Planned

- [ ] **Phase 4** — Consensus-based sync, network quality-based coordinator election, acoustic sync markers, watchOS support

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — component design, wire protocol, sync algorithm details
- [Changelog](CHANGELOG.md) — release history
- [Contributing](CONTRIBUTING.md) — how to build, test, and submit changes

## Demo Apps

### PeerClock NTP (`App/PeerClockNTP`)

Minimal NTP time display + TAP SYNC demo. Shows PeerClock's clock synchronization in action — tap a button and all connected devices flash simultaneously.

### PeerClock Metronome (`App/PeerClockMetronome`)

P2P-synchronized metronome. Multiple iPhones click in unison with ±2ms precision. Features:
- BPM adjustment (30–300), subdivisions (1/1, 1/2, 1/3, 1/4)
- Precise audio scheduling via `mach_absolute_time` + `AVAudioTime(hostTime:)`
- P2P sync: beat boundaries computed from `PeerClock.now`, BPM/subdivision/play state broadcast to peers
- Visual flash on each beat

## Background

PeerClock was born from [1Take](https://github.com/hakaru/1Take), an iOS multi-device audio recording app. The need to synchronize multiple iPhones led to the realization that P2P device coordination is a general-purpose problem with no existing Swift solution — especially not with peer-equal topology.

## License

MIT
