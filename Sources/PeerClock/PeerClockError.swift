import Foundation

/// PeerClock の公開 API がスローするエラー。
public enum PeerClockError: Error, Sendable, Equatable {
    /// PeerClock が start() されていない (eventScheduler == nil)
    case notStarted

    /// 同期されていない or 鮮度が staleAfter を超過している
    case notSynchronized

    /// 同期信頼度が Configuration.minSyncQuality を下回っている
    case qualityBelowThreshold(quality: Double, threshold: Double)

    /// 過去時刻 schedule で遅延が lateTolerance を超過している
    case deadlineExceeded(lateBy: Duration, tolerance: Duration)
}
