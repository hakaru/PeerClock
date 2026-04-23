import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "TermStore")

/// Persistent store for the highest term ever observed.
/// Used for stale-leader rejection and monotonic term advancement.
public final class TermStore: @unchecked Sendable {
    private static let userDefaultsKey = "peerclock.maxSeenTerm"

    private let lock = NSLock()
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Current persisted maximum term. Returns 0 if never set.
    public var current: UInt64 {
        lock.withLock {
            UInt64(defaults.object(forKey: Self.userDefaultsKey) as? Int64 ?? 0)
        }
    }

    /// Atomically updates max if observed > current. Returns the new max.
    @discardableResult
    public func update(observed: UInt64) -> UInt64 {
        lock.withLock {
            let raw = defaults.object(forKey: Self.userDefaultsKey) as? Int64 ?? 0
            let current = UInt64(raw)
            if observed > current {
                defaults.set(Int64(observed), forKey: Self.userDefaultsKey)
                logger.info("[TermStore] advanced \(current) → \(observed)")
                return observed
            }
            return current
        }
    }

    /// Reset to zero. For testing only.
    public func reset() {
        lock.withLock {
            defaults.removeObject(forKey: Self.userDefaultsKey)
        }
    }
}
