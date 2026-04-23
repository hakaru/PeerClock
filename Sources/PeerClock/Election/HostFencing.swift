import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "HostFencing")

/// Validates incoming term values against the local TermStore.
/// Implements stale-leader rejection per spec §5.1.
public final class HostFencing: @unchecked Sendable {
    public enum Decision: Equatable, Sendable {
        case accept              // observed >= maxSeenTerm
        case rejectStale         // observed < maxSeenTerm
        case forceDemote         // we're the host but observed > our own term
    }

    private let termStore: TermStore

    public init(termStore: TermStore) {
        self.termStore = termStore
    }

    /// Validate an incoming term observed from a peer. Updates maxSeenTerm if higher.
    /// - Parameters:
    ///   - observedTerm: term from incoming message
    ///   - localIsHost: whether we currently hold the host role
    ///   - localTerm: our current term if we're host (ignored otherwise)
    public func validate(observedTerm: UInt64, localIsHost: Bool, localTerm: UInt64 = 0) -> Decision {
        let current = termStore.current

        if observedTerm < current {
            logger.warning("[Fencing] stale leader rejected: observed=\(observedTerm) < maxSeen=\(current)")
            return .rejectStale
        }

        // observed >= current: update store
        if observedTerm > current {
            termStore.update(observed: observedTerm)
        }

        // If we're the host and observed > our term, we must demote
        if localIsHost && observedTerm > localTerm {
            logger.warning("[Fencing] force demote: observed=\(observedTerm) > localTerm=\(localTerm)")
            return .forceDemote
        }

        return .accept
    }
}
