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

    @Test("Jump stream emits old and new offset")
    func jumpStream() async throws {
        let monitor = DriftMonitor(jumpThresholdNs: 5_000_000)

        let collector = Task { () -> JumpEvent? in
            for await event in monitor.jumps {
                return event
            }
            return nil
        }

        _ = monitor.recordOffset(1_000_000)
        _ = monitor.recordOffset(20_000_000) // jump

        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.shutdown()
        let event = await collector.value
        #expect(event != nil)
        #expect(event?.oldOffsetNs == 1_000_000)
        #expect(event?.newOffsetNs == 20_000_000)
    }

    @Test("Normal updates do not emit jump events")
    func normalNoJump() async throws {
        let monitor = DriftMonitor(jumpThresholdNs: 100_000_000)

        actor Flag { var hit = false; func set() { hit = true }; func read() -> Bool { hit } }
        let flag = Flag()

        let collector = Task {
            for await _ in monitor.jumps {
                await flag.set()
                break
            }
        }

        _ = monitor.recordOffset(1_000_000)
        _ = monitor.recordOffset(2_000_000) // diff well under threshold

        try await Task.sleep(nanoseconds: 100_000_000)
        monitor.shutdown()
        collector.cancel()
        #expect(await flag.read() == false)
    }
}
