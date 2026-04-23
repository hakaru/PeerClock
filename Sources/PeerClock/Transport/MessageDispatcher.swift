import Foundation
import os

private let logger = Logger(subsystem: "net.hakaru.PeerClock", category: "MessageDispatcher")

/// Separates NTP messages from control messages to preserve timestamp precision.
/// NTP messages take priority and bypass backpressure.
/// Critical messages (start/stop) never drop. Status/heartbeat are latest-only.
public actor MessageDispatcher {
    public enum Priority: Sendable {
        case ntp       // highest — bypasses backpressure
        case critical  // start/stop — never dropped
        case control   // session_init, preset change
        case status    // latest-only, droppable
        case heartbeat // latest-only, droppable
    }

    public struct OutboundMessage: Sendable {
        public let data: Data
        public let priority: Priority
        public let id: UUID

        public init(data: Data, priority: Priority, id: UUID = UUID()) {
            self.data = data
            self.priority = priority
            self.id = id
        }
    }

    private var ntpQueue: [OutboundMessage] = []
    private var criticalQueue: [OutboundMessage] = []
    private var controlQueue: [OutboundMessage] = []
    private var latestStatus: OutboundMessage?
    private var latestHeartbeat: OutboundMessage?

    /// Buffer size limit for non-critical messages (Task 12)
    private let maxNonCriticalSize: Int = 8

    /// Backpressure detection timestamp (Task 12)
    private var backpressureStartedAt: Date?

    public init() {}

    /// Enqueue a message. Backpressure-aware:
    /// - NTP: always accepted (bypasses limit)
    /// - critical: never dropped
    /// - control: drops oldest control if over limit
    /// - status/heartbeat: latest-only (replaces previous)
    public func enqueue(_ message: OutboundMessage) {
        switch message.priority {
        case .ntp:
            ntpQueue.append(message)
        case .critical:
            criticalQueue.append(message)
        case .control:
            if controlQueue.count >= maxNonCriticalSize {
                controlQueue.removeFirst()
                logger.warning("[Dispatcher] control queue full, dropped oldest")
            }
            controlQueue.append(message)
        case .status:
            latestStatus = message
        case .heartbeat:
            latestHeartbeat = message
        }
        updateBackpressureState()
    }

    /// Pop next message in priority order: ntp > critical > control > status > heartbeat
    public func dequeue() -> OutboundMessage? {
        if !ntpQueue.isEmpty { return ntpQueue.removeFirst() }
        if !criticalQueue.isEmpty { return criticalQueue.removeFirst() }
        if !controlQueue.isEmpty { return controlQueue.removeFirst() }
        if let s = latestStatus { latestStatus = nil; return s }
        if let h = latestHeartbeat { latestHeartbeat = nil; return h }
        return nil
    }

    public var isEmpty: Bool {
        ntpQueue.isEmpty && criticalQueue.isEmpty && controlQueue.isEmpty
        && latestStatus == nil && latestHeartbeat == nil
    }

    /// Returns true if backpressure has continued for longer than threshold (Task 12).
    /// Used by host to detect slow clients and disconnect them.
    public func isSlowClient(threshold: TimeInterval = 5.0) -> Bool {
        guard let started = backpressureStartedAt else { return false }
        return Date().timeIntervalSince(started) > threshold
    }

    private func updateBackpressureState() {
        let nonCriticalCount = controlQueue.count
            + (latestStatus != nil ? 1 : 0)
            + (latestHeartbeat != nil ? 1 : 0)
        if nonCriticalCount >= maxNonCriticalSize {
            if backpressureStartedAt == nil {
                backpressureStartedAt = Date()
            }
        } else {
            backpressureStartedAt = nil
        }
    }
}
