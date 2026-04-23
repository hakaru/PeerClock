# Topology Spec (v0.4.0)

## Modes

### `.mesh`
- Transport: `WiFiTransport` (Bonjour + Network.framework TCP/UDP)
- Election: `CoordinatorElection` (smallest PeerID wins)
- Wire: binary `MessageCodec` (version byte `0x02`)
- Bonjour service type: `_peerclock._tcp` + `_peerclock._udp`
- Bit-compatible with v0.2.x (PeerClockMetronome v1.0 syncs with v0.4.0 mesh peers).

### `.star(role:)`
- Transport: `StarTransport` (host runs `NWListener`, clients `NWConnection`, RFC 6455 WebSocket)
- Election: `HostElection` actor with term/session_generation, settle period, jitter
- Wire: tagged-union JSON `ControlMessage`/`NtpMessage` over WebSocket text frames
- Bonjour service type: `_peerclockstar._tcp`
- TXT: `role`, `peer_id`, `term`, `score`, `proto_ver=2`
- Role: `.auto` (participate in election) or `.clientOnly` (never advertise as host, skip election, browse only — for AUv3 extensions)

### `.auto(heuristic:)`
- Starts in `.mesh`.
- Observes peer count. When heuristic triggers (e.g. `peerCountThreshold(5)` → peers.count ≥ 5), transitions to `.star(role: .auto)`.
- Transition is explicit: stop mesh runtime, start star runtime. Brief (~2s) disconnection window.
- No reverse transition in this release (once star, stays star).

## Cross-mode interop

Mesh and star advertise on different Bonjour service types — they do not discover each other. Intentional: a device running `.mesh` cannot sync with a device running `.star`. This is the user-visible cost of the dual-topology design.

## Default

`PeerClock()` defaults to `.mesh` to preserve v0.2.x compatibility for existing consumers (`from: "0.x"` SPM requirements).

## Breaking changes from v0.3.0-beta.1

- `PeerClock.init(transportFactory:)` removed from public API. Topology is the new knob.
- `Transport.send(_:to:)` removed from protocol (Q5:B). All delivery goes through `broadcast(_:)`; recipient filtering is the application's concern.
