# PeerClock Architecture

## Design Principles

- **All nodes are equal.** The public API has no role concept. Any device can send commands, share status, and schedule events.
- **Transparent coordinator.** Clock synchronization requires a single time reference. PeerClock auto-elects the peer with the smallest `PeerID` (UUID). The app never sees this.
- **Infrastructure only.** PeerClock routes commands and status — it does not define their semantics. Your app decides what `"com.myapp.record.start"` means.
- **Protocol at every boundary.** `Transport`, `SyncEngine`, and `CommandHandler` are protocols with immediate concrete implementations. `MockTransport` (in-memory) enables deterministic unit testing; `WiFiTransport` and `MultipeerTransport` run on real networks.

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

All integers are big-endian. Strings are UTF-8. Timestamps are `UInt64` nanoseconds based on `mach_continuous_time`.

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

- **Backoff stages:** After initial sync, re-sync interval starts at 5s and progressively extends to 10s → 20s → 30s as sync quality remains stable. Promotion requires 3 consecutive successful rounds at each stage.
- **Jump detection:** If the offset changes by more than 10ms between rounds, `DriftMonitor` triggers a full re-sync and resets the backoff to stage 0.

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

All deterministic logic is tested via `MockTransport` — an in-memory transport that simulates peer connections without real networking:

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
