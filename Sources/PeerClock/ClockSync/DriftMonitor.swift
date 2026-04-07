import Foundation

public enum DriftResult: Sendable, Equatable {
    case normal
    case jumpDetected
}

/// クロックジャンプ検知時に流すイベント。
public struct JumpEvent: Sendable, Equatable {
    public let oldOffsetNs: Int64
    public let newOffsetNs: Int64

    public init(oldOffsetNs: Int64, newOffsetNs: Int64) {
        self.oldOffsetNs = oldOffsetNs
        self.newOffsetNs = newOffsetNs
    }
}

public final class DriftMonitor: @unchecked Sendable {
    private let jumpThresholdNs: Double
    private let lock = NSLock()
    private var lastOffset: Double?

    private let (stream, continuation) = AsyncStream<JumpEvent>.makeStream()
    public var jumps: AsyncStream<JumpEvent> { stream }

    public init(jumpThresholdNs: Double = 10_000_000) {
        self.jumpThresholdNs = jumpThresholdNs
    }

    @discardableResult
    public func recordOffset(_ offsetNs: Double) -> DriftResult {
        lock.lock()
        let previous = lastOffset
        lastOffset = offsetNs
        lock.unlock()

        guard let previous else {
            return .normal
        }

        let diff = abs(offsetNs - previous)
        if diff > jumpThresholdNs {
            continuation.yield(JumpEvent(
                oldOffsetNs: Int64(previous),
                newOffsetNs: Int64(offsetNs)
            ))
            return .jumpDetected
        }
        return .normal
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastOffset = nil
    }

    public func shutdown() {
        continuation.finish()
    }
}
