> **⚠️ Archived:** This is the original v1 design document (master/slave architecture).
> PeerClock was redesigned to a peer-equal architecture in April 2026.
> The current design is documented in [ARCHITECTURE.md](../ARCHITECTURE.md)
> and [the v2 design spec](../superpowers/specs/2026-04-07-peerclock-v2-design.md).

# PeerClock — Design Document

## Overview

PeerClock is a Swift Package that provides peer-to-peer clock synchronization between iOS devices on a local network. It enables multiple devices to agree on a shared time reference within ±2ms, without requiring an external server or internet connection.

## Problem Statement

iOS devices have independent clocks with crystal oscillator drift of 20-50ppm. There is no Apple-provided API for synchronizing time between two iPhones. Existing NTP libraries (TrueTime, Kronos) only sync against external servers — they cannot synchronize two local devices with each other.

Applications requiring coordinated actions across devices (multi-device recording, synchronized playback, distributed games) have no off-the-shelf solution on iOS.

## Goals

- **±2ms precision** for clock sync between devices on the same Wi-Fi network
- **Zero external dependencies** — no server, no internet required
- **Drift-resilient** — continuous re-synchronization compensates for crystal oscillator drift
- **Graceful degradation** — falls back to MultipeerConnectivity when Wi-Fi unavailable (~50ms precision)
- **Simple API** — 5 lines of code to get synchronized time across devices

## Non-Goals

- Sub-microsecond precision (requires hardware word clock, impossible on iPhone)
- Audio/video processing (consumers handle their own media)
- File transfer between devices
- More than ~20 devices (designed for small peer groups)

---

## Architecture

### Component Overview

```
┌─────────────────────────────────────────────────┐
│                  PeerClock (Public API)          │
│  .master() / .slave() / .now / .schedule()      │
├─────────────────────────────────────────────────┤
│                                                  │
│  ┌──────────────┐  ┌───────────────────────┐    │
│  │  Discovery    │  │  ClockSync Engine     │    │
│  │  (Bonjour)   │──│  (NTP 4-timestamp)    │    │
│  └──────────────┘  │  (Best-half filter)   │    │
│                     │  (Periodic re-sync)   │    │
│  ┌──────────────┐  └───────────────────────┘    │
│  │  Transport    │                               │
│  │  ├ WiFiUDP    │  ┌───────────────────────┐    │
│  │  └ Multipeer  │  │  EventScheduler       │    │
│  │   (fallback)  │──│  (mach_absolute_time) │    │
│  └──────────────┘  └───────────────────────┘    │
│                                                  │
└─────────────────────────────────────────────────┘
```

### Layer 1: Discovery

**Technology:** Bonjour via `NWBrowser` / `NWListener` (Network.framework)

- Master advertises `_peerclock._udp` service on local network
- Slaves browse for service and discover master automatically
- Service includes metadata: device name, role, protocol version

**Why Bonjour:** Zero-config, built into iOS, no external infrastructure. Works on any local network.

### Layer 2: Transport

**Primary:** Wi-Fi UDP via `NWConnection` (Network.framework)

- UDP for clock sync packets (latency-sensitive, loss-tolerant)
- TCP for control messages (reliable commands: start/stop/configure)

**Fallback:** MultipeerConnectivity

- Activates when no shared Wi-Fi network detected
- Uses Wi-Fi Direct + Bluetooth automatically
- Higher latency (~50-100ms) but works in field conditions
- Same ClockSync engine, different transport

### Layer 3: ClockSync Engine

**Algorithm:** NTP-inspired 4-timestamp exchange

```
Client (Slave)              Server (Master)
    │                            │
    │──── t0 (send) ────────────>│
    │                     t1 (receive)
    │                     t2 (reply)
    │<─── t2,t1 ────────────────│
    │ t3 (receive)               │
    │                            │
    offset = (t1-t0 + t2-t3) / 2
    delay  = (t3-t0) - (t2-t1)
```

**Filtering:**

1. Collect 40 measurements at 30ms intervals (initial sync: ~1.2 seconds)
2. Sort by round-trip delay (ascending)
3. Use only the fastest 50% (best-half filtering)
4. Calculate mean offset from filtered set

**Maintenance:**

- After initial sync, re-measure every 5 seconds
- Rolling window of 40 measurements
- Detects and compensates for clock drift in real-time
- If offset suddenly jumps >10ms, trigger full re-sync

### Layer 4: Event Scheduler

**Mechanism:** `mach_absolute_time` + synchronized offset

```swift
// Convert synchronized target time to local mach time
let localFireTime = targetSyncTime - clockOffset
// Use dispatch or RunLoop for sub-ms scheduling
```

**Precision guarantee:** ±2ms under normal Wi-Fi conditions.

---

## Clock Drift Analysis

iPhone crystal oscillators drift at 20-50ppm:

| Recording Duration | Max Drift (50ppm) | Re-sync Interval | Residual Error |
|-------------------|-------------------|-------------------|----------------|
| 5 seconds | 0.25ms | 5s | <0.25ms |
| 1 minute | 3ms | 5s | <0.25ms |
| 5 minutes | 15ms | 5s | <0.25ms |
| 30 minutes | 90ms | 5s | <0.25ms |
| 2 hours | 360ms | 5s | <0.25ms |

With 5-second re-sync, drift never accumulates beyond one re-sync interval regardless of recording duration.

---

## Failure Modes

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Wi-Fi disconnect | NWConnection state change | Switch to MultipeerConnectivity |
| Master disappears | Heartbeat timeout (10s) | Slaves continue independently, re-discover |
| High network jitter | Round-trip delay >100ms | Discard measurement, retry |
| Clock jump (NTP update) | Offset change >50ms | Full re-sync cycle |
| Background suspension | `UIApplication` state | Resume sync on foreground |

---

## Wire Protocol

### Clock Sync Packet (UDP, 32 bytes)

```
┌─────────┬──────────┬──────────┬──────────┬──────────┐
│ Version │ Type     │ Seq      │ t0/t1/t2 │ Reserved │
│ 1 byte  │ 1 byte   │ 2 bytes  │ 24 bytes │ 4 bytes  │
└─────────┴──────────┴──────────┴──────────┴──────────┘

Type:
  0x01 = PING  (client→server, carries t0)
  0x02 = PONG  (server→client, carries t1, t2)

Timestamps: UInt64 nanoseconds (mach_continuous_time based)
```

### Control Packet (TCP, variable length)

```
┌─────────┬──────────┬──────────┬─────────────┐
│ Version │ Command  │ Length   │ Payload     │
│ 1 byte  │ 1 byte   │ 2 bytes  │ N bytes     │
└─────────┴──────────┴──────────┴─────────────┘

Commands:
  0x10 = SCHEDULE_EVENT (fireTime: UInt64, eventId: UUID)
  0x11 = CANCEL_EVENT   (eventId: UUID)
  0x20 = DEVICE_INFO    (name, battery, storage)
  0x30 = HEARTBEAT
  0xFF = DISCONNECT
```

---

## Security Considerations

- **Local network only** — no internet exposure
- **No encryption in v1** — trusted local network assumption
- **Future:** TLS for control channel, DTLS for UDP (v2)
- **iOS Local Network permission** required (Info.plist `NSLocalNetworkUsageDescription`)

---

## Platform Requirements

- iOS 17.0+ (Network.framework NWBrowser requires iOS 13+, but targeting 17 for modern concurrency)
- Swift 6.0+ (strict concurrency)
- `NSLocalNetworkUsageDescription` in Info.plist
- `NSBonjourServices` in Info.plist: `["_peerclock._udp"]`

---

## Implementation Phases

### Phase 1: Core Clock Sync (MVP)
- Bonjour discovery (master/slave)
- UDP 4-timestamp exchange
- Best-half filtering
- Periodic re-sync (5s interval)
- `PeerClock.now` API
- Unit tests with mock transport

### Phase 2: Event Scheduling
- `PeerClock.schedule(at:)` API
- `mach_absolute_time` based precision scheduling
- Event cancellation
- Multi-slave broadcast

### Phase 3: Resilience
- MultipeerConnectivity fallback
- Automatic transport switching
- Background mode handling
- Reconnection logic

### Phase 4: Advanced
- Acoustic sync marker support (ultrasonic pulse generation + cross-correlation)
- Clock quality metrics reporting
- Multi-master negotiation (automatic master election)
- watchOS support

---

## Success Metrics

- Clock offset ≤ 2ms on 95th percentile (same Wi-Fi)
- Clock offset ≤ 50ms on MultipeerConnectivity fallback
- Initial sync completes in < 2 seconds
- Zero drift accumulation over 2+ hour sessions
- Works with 2-10 devices simultaneously

---

## References

- [BeatSync](https://github.com/freeman-jiang/beatsync) — NTP-inspired multi-device audio sync (web)
- [TrueTime.swift](https://github.com/instacart/TrueTime.swift) — iOS NTP client
- [Kronos](https://github.com/MobileNativeFoundation/Kronos) — iOS NTP client
- [UltraSync BLUE](https://www.timecodesystems.com/products-home/ultrasyncblue/) — Hardware timecode sync over Bluetooth
- [Final Cut Camera](https://support.apple.com/en-us/120071) — Apple's multi-device camera sync (Continuity-based)
- [RFC 5905](https://tools.ietf.org/html/rfc5905) — NTPv4 specification
