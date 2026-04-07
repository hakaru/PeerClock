import Foundation

public enum DriftResult: Sendable, Equatable {
    case normal
    case jumpDetected
}

public final class DriftMonitor: @unchecked Sendable {
    private let jumpThresholdNs: Double
    private let lock = NSLock()
    private var lastOffset: Double?

    public init(jumpThresholdNs: Double = 10_000_000) {
        self.jumpThresholdNs = jumpThresholdNs
    }

    @discardableResult
    public func recordOffset(_ offsetNs: Double) -> DriftResult {
        lock.lock()
        defer { lock.unlock() }

        guard let previous = lastOffset else {
            lastOffset = offsetNs
            return .normal
        }

        let diff = abs(offsetNs - previous)
        lastOffset = offsetNs
        return diff > jumpThresholdNs ? .jumpDetected : .normal
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastOffset = nil
    }
}
