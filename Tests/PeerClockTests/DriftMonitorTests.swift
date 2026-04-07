import Testing
import Foundation
@testable import PeerClock

@Suite("DriftMonitor")
struct DriftMonitorTests {
    @Test("Detects offset jump exceeding threshold")
    func detectsJump() {
        let monitor = DriftMonitor(jumpThresholdNs: 10_000_000)
        monitor.recordOffset(1_000_000.0)
        let result1 = monitor.recordOffset(2_000_000.0)
        #expect(result1 == .normal)
        let result2 = monitor.recordOffset(15_000_000.0)
        #expect(result2 == .jumpDetected)
    }

    @Test("Normal drift does not trigger jump")
    func normalDrift() {
        let monitor = DriftMonitor(jumpThresholdNs: 10_000_000)
        monitor.recordOffset(1_000_000.0)
        let result = monitor.recordOffset(1_500_000.0)
        #expect(result == .normal)
    }

    @Test("First measurement is always normal")
    func firstMeasurement() {
        let monitor = DriftMonitor(jumpThresholdNs: 10_000_000)
        let result = monitor.recordOffset(100_000_000.0)
        #expect(result == .normal)
    }
}
