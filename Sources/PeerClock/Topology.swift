import Foundation

/// Network topology selection for a `PeerClock` instance.
///
/// See `docs/spec/topology.md`.
public enum Topology: Sendable {
    case mesh
    case star(role: StarRole)
    case auto(heuristic: AutoHeuristic)

    public static func star() -> Topology { .star(role: .auto) }
    public static func auto() -> Topology { .auto(heuristic: .peerCountThreshold(5)) }
}

/// Behavior when a peer runs in `.star` mode.
public enum StarRole: Sendable, Equatable {
    /// Participate in `HostElection`; may be elected host.
    case auto
    /// Never become host. For AUv3 extensions. See `docs/spec/client-only-role.md`.
    case clientOnly
}

/// Heuristic that drives the `.auto` mode transition from mesh to star.
public enum AutoHeuristic: Sendable, Equatable {
    /// Transition when discovered peers (including self) ≥ `n` for a settle window.
    case peerCountThreshold(Int)
}
