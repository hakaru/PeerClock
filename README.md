# PeerClock

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

No existing Swift library combines peer-equal clock sync, generic commands, and status sharing.

## Use Cases

- **Multi-device audio recording** — Start recording on multiple iPhones simultaneously with sample-accurate alignment
- **Multi-camera video capture** — Synchronize timecode across devices for post-production
- **Synchronized playback** — Play audio/video in perfect sync across devices
- **Device fleet management** — Monitor battery, storage, state across connected devices
- **Any P2P app** needing devices to agree on "now" and coordinate actions

## API

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

## Architecture

```
PeerClock (Facade — all peers equal, no roles)
│
├── Transport          Protocol: reliable + unreliable channels
│   ├── WiFiTransport  Network.framework (UDP + TCP)
│   └── MockTransport  In-memory (for testing)
│
├── Coordination       Auto coordinator election (smallest PeerID)
│                      Transparent to app — no API exposure
│
├── ClockSync          NTP-inspired 4-timestamp exchange
│   ├── NTPSyncEngine  40 measurements, best-half filtering
│   └── DriftMonitor   Jump detection (>10ms → full re-sync)
│
├── Command            Generic command send/broadcast
│   └── CommandRouter  App defines semantics, PeerClock routes
│
└── Wire               Binary protocol (5-byte header + payload)
    └── MessageCodec   Encode/decode, transport-agnostic
```

### Clock Synchronization

1. **Discovery** — All nodes browse + advertise via Bonjour
2. **Coordinator election** — Smallest PeerID becomes sync reference (automatic, invisible to app)
3. **4-timestamp exchange** — NTP-inspired: `offset = ((t1-t0) + (t2-t3)) / 2`
4. **Best-half filtering** — 40 measurements, sort by RTT, use fastest 50%
5. **Periodic re-sync** — Every 5 seconds to correct crystal oscillator drift (20-50ppm)
6. **Jump detection** — Offset change >10ms triggers full re-sync

### Precision Budget

| Source | Error | Mitigation |
|--------|-------|------------|
| Wi-Fi UDP jitter | 1-10ms | Best-half filtering → ~1-2ms |
| Crystal oscillator drift | 50ppm = 0.25ms/5s | 5s periodic re-sync |
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

## Roadmap

### Phase 1: Transport + ClockSync + Command ✅

- [x] Peer-equal architecture (no master/slave)
- [x] Transport protocol abstraction (reliable / unreliable)
- [x] Bonjour discovery (all nodes browse + advertise)
- [x] Coordinator auto-election (smallest PeerID)
- [x] NTP-inspired 4-timestamp clock sync + best-half filtering
- [x] Drift monitoring and jump detection
- [x] Generic command channel (send / broadcast)
- [x] Wire protocol codec (5-byte header, transport-agnostic)
- [x] MockTransport for unit testing
- [x] WiFiTransport (Network.framework UDP/TCP)
- [x] PeerClock facade (role-free public API)

### Phase 2: Status + Event Scheduling

- [ ] Status registry (common `pc.*` + custom app-defined keys)
- [ ] Status push (auto-broadcast on change) + pull (on-demand request)
- [ ] Status generation counter for freshness
- [ ] Debounce for high-frequency status updates
- [ ] Heartbeat + connection state (connected → degraded → disconnected)
- [ ] Event scheduler (`mach_absolute_time` precision firing)

### Phase 3: Resilience

- [ ] MultipeerConnectivity fallback transport (~50ms precision)
- [ ] Automatic transport switching (Wi-Fi → MPC)
- [ ] Reconnection logic + coordinator re-election
- [ ] Background mode handling

### Phase 4: Advanced Sync

- [ ] Consensus-based sync (all-pairs measurement, median reference)
- [ ] Network quality-based coordinator election
- [ ] Clock quality metrics reporting
- [ ] Acoustic sync markers (ultrasonic pulse + cross-correlation)
- [ ] watchOS support

## Background

PeerClock was born from [1Take](https://github.com/hakaru/1Take), an iOS multi-device audio recording app. The need to synchronize multiple iPhones led to the realization that P2P device coordination is a general-purpose problem with no existing Swift solution — especially not with peer-equal topology.

## License

MIT
