#if DEBUG
import Foundation

/// Test-only fault injection hooks for PeerClock components.
/// Available in DEBUG builds. Production code should not depend on these.
public actor PeerClockTestHooks {
    public static let shared = PeerClockTestHooks()

    public enum Fault: Sendable {
        case dropOutgoingRate(Double)        // 0.0..1.0
        case partition(peerIDs: Set<UUID>)   // simulate disconnect from these peers
        case killHost                        // immediate host stop
    }

    private var activeFaults: [Fault] = []

    private init() {}

    public func inject(_ fault: Fault) {
        activeFaults.append(fault)
    }

    public func clear() {
        activeFaults.removeAll()
    }

    public var faults: [Fault] {
        activeFaults
    }

    /// Returns true if the given outgoing send should be dropped.
    public func shouldDropSend() -> Bool {
        for fault in activeFaults {
            if case .dropOutgoingRate(let rate) = fault, Double.random(in: 0...1) < rate {
                return true
            }
        }
        return false
    }

    /// Returns true if traffic to the given peer should be blocked.
    public func isPeerPartitioned(_ peerID: UUID) -> Bool {
        for fault in activeFaults {
            if case .partition(let set) = fault, set.contains(peerID) {
                return true
            }
        }
        return false
    }

    /// Returns true if the local host should be force-killed.
    public func shouldKillHost() -> Bool {
        activeFaults.contains(where: {
            if case .killHost = $0 { return true } else { return false }
        })
    }
}
#endif
