# Mesh Wire Compatibility Matrix (v0.2.x ↔ v0.4.0)

## Bit-compat requirement

v0.4.0 `.mesh` must produce **byte-identical** output to v0.2.x for every wire-visible structure. Any divergence breaks PeerClockMetronome v1.0 sync.

## Covered surfaces

| Surface | Producer | File | v0.2.x hash | Test |
|---------|----------|------|-------------|------|
| Bonjour service type (TCP) | Discovery | `Transport/Discovery.swift` | `_peerclock._tcp` | constant match |
| Bonjour service type (UDP) | Discovery | `Transport/Discovery.swift` | `_peerclock._udp` | constant match |
| Message header byte 0 (version) | MessageCodec | `Wire/MessageCodec.swift` | `0x02` | golden |
| `.hello(peerID, protocolVersion)` encoding | MessageCodec | — | (type `0x01`) | golden |
| `.ping/.pong` encoding | MessageCodec | — | (type `0x02`/`0x03`) | golden |
| `.commandBroadcast` encoding | MessageCodec | — | (type `0x10`) | golden |
| `.commandUnicast` encoding | MessageCodec | — | (type `0x11`) | golden |
| `.heartbeat` encoding | MessageCodec | — | (type `0x20`) | golden |
| `.statusPush/.statusRequest/.statusResponse` | MessageCodec | — | (types `0x30`/`0x31`/`0x32`) | golden |
| `.disconnect` encoding | MessageCodec | — | (type `0xFF`) | golden |
| NTP 4-timestamp exchange | NTPSyncEngine | `ClockSync/NTPSyncEngine.swift` | (via Ping/Pong) | integration |

## Golden-file test procedure

1. Check out v0.2.1 tag in a temporary worktree.
2. Run a helper target that encodes one of each `Message` variant with deterministic inputs.
3. Save bytes to `Tests/PeerClockTests/Fixtures/wire-v2/<variant>.bin`.
4. v0.4.0 `WireCompatGoldenTests` re-encodes with the same inputs and asserts byte-identity.

## Deviations allowed

None. If a wire change is necessary, bump to v0.5.0 and document the break.
