# `.auto` Topology Heuristic

## Trigger

`AutoHeuristic.peerCountThreshold(N)` — transition from mesh → star when **distinct** Bonjour-discovered peers (including self) ≥ N for at least `settleWindow` (default 3s).

Settle window prevents flapping on short-lived discovery races.

## Transition procedure

1. Record the peer-count threshold crossing timestamp.
2. After `settleWindow`, if still above threshold, begin transition.
3. `MeshRuntime.stop()` — cancels streams, closes connections, unadvertises.
4. Emit `TopologyEvent.transitionStarted(from: .mesh, to: .star(.auto))` on a dedicated AsyncStream.
5. `StarRuntime.start()` — registers BonjourAdvertiser on `_peerclockstar._tcp`, begins HostElection.
6. Re-publish `PeerClock.peers` once election settles.

## No reverse

Once in star, stays in star for the lifetime of the `PeerClock` instance. A user who wants to return to mesh must `stop()` and create a new `PeerClock(topology: .mesh)`.

## Rationale

- Star topology shines at 5+ devices (mesh N² connections become wasteful).
- Below 5 devices, mesh avoids a single point of failure (host election + host kill).
- The threshold is configurable (`.peerCountThreshold(N)`) for future tuning.

## Future heuristics (not in v0.4.0)

- `networkType(.cellular → .mesh)` — mesh only on local Wi-Fi
- `deviceClass(.lowPower → .clientOnly)` — weak devices never host
