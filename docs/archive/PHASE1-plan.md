> **⚠️ Archived:** This was the Phase 1 implementation plan. Phase 1 shipped as v0.1.0
> on 2026-04-07. See [CHANGELOG.md](../../CHANGELOG.md) for the release summary.

# PeerClock Phase 1 — Implementation Plan

**Date:** 2026-04-07
**Status:** Approved
**Target:** PeerClock v0.1.0

## Goal

Ship the minimum viable peer-equal clock synchronization library: two iOS devices on the same Wi-Fi can agree on "now" within ±2ms, with no master/slave roles, no external server, no internet.

## Scope

### v0.1 includes

- Bonjour discovery (NWBrowser + NWListener)
- UDP transport (Network.framework)
- NTP-inspired 4-timestamp clock sync protocol
- Best-half measurement filtering (40 measurements, fastest 50%)
- Periodic re-sync (every 5 seconds for drift correction)
- Peer-equal architecture (auto coordinator election by smallest PeerID)
- Basic command channel (broadcast + send-to-peer)
- `PeerClock.now` synchronized timestamp API
- MockTransport for unit tests
- Wire protocol codec (binary, transport-agnostic)

### v0.1 excludes

- MultipeerConnectivity fallback (Phase 3)
- Event scheduling (Phase 2)
- Status registry (Phase 2)
- Acoustic sync markers (Phase 4)
- watchOS support (Phase 4)
- TLS/encryption (Phase 4)

## Architecture

```
┌────────────────────────────────────────┐
│         PeerClock (Public Facade)       │
│  start() / stop() / now / commands /    │
│  broadcast() / send() / peers           │
├────────────────────────────────────────┤
│                                         │
│  ┌──────────────┐  ┌─────────────────┐ │
│  │  Discovery    │  │  Coordinator    │ │
│  │  (Bonjour)   │──│  Election       │ │
│  └──────────────┘  │  (smallest UUID)│ │
│                     └─────────────────┘ │
│  ┌──────────────┐                      │
│  │  Transport    │  ┌─────────────────┐│
│  │  Protocol    │──│  ClockSync       ││
│  │   ├ WiFi     │  │  Engine          ││
│  │   └ Mock     │  │  (NTP 4-stamp)   ││
│  └──────────────┘  └─────────────────┘ │
│                                         │
│  ┌──────────────┐  ┌─────────────────┐ │
│  │  Wire Codec   │  │  Command Router │ │
│  │  (5-byte     │  │  (broadcast /   │ │
│  │   header)    │  │   unicast)      │ │
│  └──────────────┘  └─────────────────┘ │
└────────────────────────────────────────┘
```

## Module Breakdown

### 1. Transport Protocol

```swift
public protocol Transport: Sendable {
    func start() async throws
    func stop() async
    var peers: AsyncStream<Set<PeerID>> { get }
    var incomingMessages: AsyncStream<(PeerID, Data)> { get }
    func send(_ data: Data, to peer: PeerID) async throws
    func broadcast(_ data: Data) async throws
}
```

### 2. WiFiTransport

`Network.framework` based UDP + TCP transport.

- Bonjour discovery via `NWBrowser` (browse `_peerclock._udp` service)
- Bonjour advertisement via `NWListener`
- UDP for clock sync packets (`NWConnection` with `.udp` parameters)
- TCP for control/command packets (`NWConnection` with `.tcp`)
- Peer connection lifecycle management

### 3. ClockSyncEngine

NTP-inspired 4-timestamp exchange:

```
peer A → peer B:  [PING, t0]
peer B → peer A:  [PONG, t0, t1, t2]
peer A computes:  offset = ((t1 - t0) + (t2 - t3)) / 2
                  delay  = (t3 - t0) - (t2 - t1)
```

- 40 measurements collected at 30ms intervals
- Sort by `delay`, use fastest 50%
- Average the offsets from filtered set
- Re-sync every 5 seconds (drift correction)
- Use `mach_continuous_time` (monotonic, survives sleep) for local timestamps

### 4. CoordinatorElection

- All peers exchange PeerID on connection
- Smallest UUID becomes coordinator
- Coordinator is the clock reference for new peers joining mid-session
- Re-election if coordinator disconnects
- Transparent to app (no API exposure)

### 5. Wire Codec

Binary protocol, 5-byte header + payload:

```
┌─────────┬──────────┬──────────┬─────────────┐
│ Version │ Type     │ Length   │ Payload     │
│ 1 byte  │ 1 byte   │ 2 bytes  │ N bytes     │
└─────────┴──────────┴──────────┴─────────────┘
```

Message types:
- `0x01` HELLO (PeerID exchange, version negotiation)
- `0x02` PING (clock sync request)
- `0x03` PONG (clock sync response with t1, t2)
- `0x10` COMMAND_BROADCAST
- `0x11` COMMAND_UNICAST
- `0x20` HEARTBEAT
- `0xFF` DISCONNECT

### 6. PeerClock Facade

```swift
public final class PeerClock: Sendable {
    public init(configuration: Configuration = .default)
    public func start() async throws
    public func stop() async
    public var now: TimeInterval { get }  // Synchronized time
    public var peers: AsyncStream<Set<PeerID>> { get }
    public var commands: AsyncStream<(PeerID, Command)> { get }
    public func broadcast(_ command: Command) async throws
    public func send(_ command: Command, to peer: PeerID) async throws
}
```

## Implementation Phases (within v0.1)

### Phase 1.1 — Wire Codec + MockTransport (1 week)

- Implement message encoder/decoder
- Define `Message` enum
- Implement `MockTransport` for in-memory peer simulation
- Unit tests for encoding/decoding round-trip
- Unit tests for mock peer-to-peer messaging

### Phase 1.2 — ClockSyncEngine (1 week)

- 4-timestamp exchange logic
- Best-half filtering algorithm
- Drift correction over time
- Unit tests using MockTransport (simulate latency, jitter)
- Verify ±2ms precision under simulated 10ms RTT

### Phase 1.3 — WiFiTransport (1-2 weeks)

- `NWBrowser` discovery
- `NWListener` advertisement
- UDP `NWConnection` for clock sync
- TCP `NWConnection` for commands
- Reconnection handling
- Manual integration test on two physical iPhones

### Phase 1.4 — Coordinator Election (3 days)

- HELLO message exchange
- Smallest UUID wins
- Re-election on disconnect
- Unit tests with MockTransport (multi-peer scenarios)

### Phase 1.5 — Command Channel (3 days)

- Broadcast and unicast send APIs
- Command receive AsyncStream
- Test with MockTransport

### Phase 1.6 — PeerClock Facade + Integration (1 week)

- Public API surface
- Wire all modules together
- Integration tests on physical devices
- Sample iOS test app

## Testing Strategy

### Unit Tests (MockTransport)

- All deterministic logic: codec, sync algorithm, election, command routing
- Simulate network conditions: latency, jitter, packet loss
- Multi-peer scenarios

### Integration Tests (Physical Devices)

- 2 iPhones on same Wi-Fi
- Verify ±2ms clock agreement
- Verify peer discovery within 5 seconds
- Verify reconnection after Wi-Fi blip
- Verify drift stays bounded over 30+ minute session

### Performance Tests

- Initial sync should complete within 2 seconds (40 measurements × 30ms)
- Steady-state CPU usage <0.5%
- Memory footprint <2MB

## Success Criteria

1. Two iPhones on same Wi-Fi agree on `clock.now` within ±2ms (95th percentile)
2. Peer discovery completes within 5 seconds of `start()`
3. Drift stays bounded indefinitely (re-sync working)
4. All unit tests pass with MockTransport
5. Integration test on real hardware succeeds repeatedly
6. Public API documented with DocC
7. README has working code example

## Open Questions

None. All design decisions are finalized.

## References

- [PeerClock DESIGN.md](../docs/DESIGN.md)
- [BeatSync](https://github.com/freeman-jiang/beatsync) — NTP-inspired sync (web)
- RFC 5905 — NTPv4 specification
