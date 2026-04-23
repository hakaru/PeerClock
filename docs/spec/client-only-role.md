# Client-Only Star Role (for AUv3 extensions)

## Motivation

iOS App Extensions (AUv3) have:
- No guaranteed `NWListener` lifetime (host process may suspend/kill the extension)
- Lower memory ceiling
- Background-mode constraints

Running `StarHost` in an AUv3 extension risks: silent listener death, port reuse conflicts, NWListener failing to rebind after host suspension. Apple has no officially supported pattern for server sockets in extensions.

## Behavior

`PeerClock(topology: .star(role: .clientOnly))`:

1. Does **not** call `HostElection.start()`.
2. Does **not** publish a Bonjour service for hosting (`role=host` never broadcast).
3. **Does** publish a Bonjour service for visibility (`role=client-only` in TXT) so hosts know this peer will not volunteer as host.
4. Uses `BonjourBrowser` only to find the current host.
5. `StarClient` connects to whichever peer advertises `role=host`.
6. If no host exists (all peers are client-only), sync never establishes — the app displays "no host available" via `PeerClock.syncState = .idle`.

## TXT contract

Client-only peers advertise `_peerclockstar._tcp` with TXT:
```
role=client-only
peer_id=<uuid>
proto_ver=2
```

Score/term are absent (client-only peers do not participate in election).

## Host-side responsibility

`HostElection` must ignore peers with `role=client-only` when computing score/quorum. They contribute to peer count but not to host candidacy.
