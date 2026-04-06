# PeerClock

Sub-millisecond P2P clock synchronization between iOS devices over local network.

## What is PeerClock?

PeerClock is a Swift library that synchronizes clocks across multiple iPhones and iPads on the same local network — **without an external server**. Each device agrees on "what time it is" within ~2ms, enabling coordinated actions like simultaneous recording, playback, or any event that needs to happen at the same instant on multiple devices.

## How is this different from TrueTime / Kronos?

| | TrueTime / Kronos | PeerClock |
|--|-------------------|-----------|
| Sync target | External NTP server | Nearby iPhone/iPad (P2P) |
| Internet | Required | Not required |
| Use case | "Get accurate wall-clock time" | "Make 2+ devices act simultaneously" |
| Protocol | SNTP (RFC 4330) | Custom NTP-inspired 4-timestamp exchange |

## Use Cases

- **Multi-device audio recording** — Start recording on multiple iPhones simultaneously with sample-accurate alignment
- **Multi-camera video capture** — Synchronize timecode across devices for post-production editing
- **Synchronized playback** — Play audio/video in perfect sync across a room of devices
- **Distributed timers** — Coordinated countdowns, game events, IoT sensor timestamps
- **Any P2P app** needing devices to agree on "now"

## Architecture

```
┌──────────────────────────────────────────────┐
│              PeerClock Protocol               │
├──────────────────────────────────────────────┤
│                                              │
│  Layer 1: Discovery                          │
│  └── Bonjour (NWBrowser) on local network    │
│                                              │
│  Layer 2: Clock Sync                         │
│  └── UDP 4-timestamp exchange (NTP-inspired) │
│      40 measurements → best-half filtering   │
│      Periodic re-sync for drift correction   │
│                                              │
│  Layer 3: Coordinated Events                 │
│  └── "Execute at T+offset" scheduling        │
│      All devices fire within ±2ms            │
│                                              │
│  Layer 4: Fallback                           │
│  └── MultipeerConnectivity (no Wi-Fi)        │
│      Reduced precision (~50ms) but works     │
│                                              │
└──────────────────────────────────────────────┘
```

## Planned API

```swift
import PeerClock

// Master device
let clock = PeerClock(role: .master)
clock.start()

// Slave device
let clock = PeerClock(role: .slave)
clock.join(master: discoveredPeer)

// Schedule synchronized event
let fireTime = clock.now + .seconds(2)
clock.schedule(at: fireTime) {
    // Executes simultaneously on all devices (±2ms)
    recorder.start()
}

// Read synchronized time
let syncedTimestamp = clock.now  // Agrees across all devices
```

## Technical Details

### Clock Synchronization Protocol

1. **Discovery** — Bonjour service advertisement on local network
2. **Handshake** — TCP connection for reliable control messages
3. **Clock sync** — UDP 4-timestamp exchange (NTP algorithm):
   - Client sends t0 (departure)
   - Server records t1 (receipt), t2 (response)
   - Client records t3 (arrival)
   - Offset = (t1-t0 + t2-t3) / 2
4. **Filtering** — 40 measurements, sort by round-trip delay, use best 50%
5. **Maintenance** — Re-sync every 5 seconds to correct crystal oscillator drift (~20-50ppm)

### Precision Budget

| Source | Error | Mitigation |
|--------|-------|------------|
| Wi-Fi UDP jitter | 1-10ms | Best-half filtering reduces to ~1-2ms |
| Crystal oscillator drift | 50ppm = 0.25ms/5s | Periodic re-sync |
| iOS scheduling | <1ms | `mach_absolute_time` for sub-ms timing |
| **Total** | **±2ms typical** | |

### Fallback: MultipeerConnectivity

When no Wi-Fi network is available, PeerClock falls back to MultipeerConnectivity (Wi-Fi Direct + Bluetooth). Precision drops to ~50ms but connectivity is maintained. Post-processing with acoustic markers can recover sub-ms precision.

## Requirements

- iOS 17.0+
- Swift 6.0+
- Same local Wi-Fi network (primary) or Bluetooth range (fallback)

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/hakaru/PeerClock.git", from: "0.1.0")
]
```

## Roadmap

- [ ] Core NTP-inspired clock sync protocol
- [ ] Bonjour discovery
- [ ] Master/slave role management
- [ ] Coordinated event scheduling
- [ ] MultipeerConnectivity fallback
- [ ] Acoustic sync marker support (ultrasonic pulse for sub-sample alignment)
- [ ] Clock drift monitoring and reporting
- [ ] watchOS support

## Background

PeerClock was born from [1Take](https://github.com/hakaru/1Take), an iOS audio recording app. The need to synchronize multiple iPhones for multi-device recording led to the realization that P2P clock synchronization is a general-purpose problem with no existing Swift solution.

## License

MIT
