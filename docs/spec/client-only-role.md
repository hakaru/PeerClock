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
2. Does **not** publish a Bonjour service (`BonjourAdvertiser` requires an
   `NWListener`, which AUv3 extensions cannot reliably run — that's the
   motivation for this role). Client-only peers are therefore invisible to
   Bonjour discovery by other peers.
3. Since client-only peers are invisible in Bonjour, they cannot be
   mis-elected as hosts. The `HostElection` filter on `role == "client-only"`
   (below) is a defensive measure in case a future client-only advertising
   mechanism is added, or to reject peers that self-identify as client-only
   via a connected StarClient channel.
4. Uses `BonjourBrowser` only to find the current host.
5. `StarClient` connects to whichever peer advertises `role=host`.
6. If no host exists (all peers are client-only), sync never establishes — the app displays "no host available" via `PeerClock.syncState = .idle`.

## TXT contract (future)

If a future mechanism adds client-only Bonjour advertising (e.g. a shared
listener managed by the host app process, outside the AUv3 extension), the
TXT shape must be:

- `role=client-only`
- `peer_id=<uuid>`
- `version=3` (matches `BonjourAdvertiser.TXTRecord.version`)

Score and term fields are absent (client-only peers do not participate in
election).

## Host-side responsibility

`HostElection` must ignore peers with `role=client-only` when computing score/quorum. They contribute to peer count but not to host candidacy.
