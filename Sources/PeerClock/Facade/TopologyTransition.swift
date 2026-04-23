import Foundation

/// Event emitted by a topology runtime when it's ready to transition its
/// underlying component stack (e.g. `.auto` mesh → star crossing a threshold).
///
/// `PeerClock` subscribes to `TopologyRuntime.transitionEvents` and orchestrates
/// a service-layer rebuild against the new transport when a transition fires.
internal struct TopologyTransition: Sendable, Equatable {
    internal enum Kind: Sendable, Equatable { case meshToStar }
    internal let kind: Kind
    internal let at: Date

    internal init(kind: Kind, at: Date = Date()) {
        self.kind = kind
        self.at = at
    }
}
