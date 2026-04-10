import Foundation

/// Errors thrown by the `PeerClock` public API.
public enum PeerClockError: Error, Sendable, Equatable {
    /// `start()` has not been called yet.
    case notStarted

    /// Clock is not synchronized or the last sync exceeds
    /// `Configuration.syncStaleAfter`.
    case notSynchronized

    /// Sync confidence is below `Configuration.minSyncQuality`.
    case qualityBelowThreshold(quality: Double, threshold: Double)

    /// The requested schedule time has already passed beyond the allowed
    /// tolerance.
    case deadlineExceeded(lateBy: Duration, tolerance: Duration)
}
