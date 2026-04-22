import Darwin
import Foundation
import PeerClock

/// Thread-safe facade over PeerClock for synced time ↔ host time conversions.
/// Exposes nonisolated accessors so beat/audio paths can convert without actor hops.
final class PeerClockTimebase: @unchecked Sendable {
    private let clock: PeerClock

    private static let machTimebase: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    init(clock: PeerClock) {
        self.clock = clock
    }

    /// Current synced time in nanoseconds (PeerClock.now).
    func syncedNow() -> UInt64 {
        clock.now
    }

    /// Convert a future synced time (ns) to a host time (mach_absolute_time units)
    /// suitable for AVAudioTime scheduling.
    func hostTime(forSyncedTime syncedNs: UInt64,
                  referenceHostTime: UInt64 = mach_absolute_time()) -> UInt64 {
        let syncedNow = clock.now
        if syncedNs > syncedNow {
            let deltaNs = syncedNs - syncedNow
            return referenceHostTime + UInt64(Double(deltaNs) / Self.machTimebase)
        }
        return referenceHostTime
    }

    /// Convert a host time to synced time (ns).
    func syncedTime(forHostTime hostTime: UInt64,
                    referenceHostTime: UInt64 = mach_absolute_time()) -> UInt64 {
        let syncedNow = clock.now
        if hostTime >= referenceHostTime {
            let deltaMach = hostTime - referenceHostTime
            let deltaNs = UInt64(Double(deltaMach) * Self.machTimebase)
            return syncedNow &+ deltaNs
        } else {
            let deltaMach = referenceHostTime - hostTime
            let deltaNs = UInt64(Double(deltaMach) * Self.machTimebase)
            return syncedNow > deltaNs ? syncedNow - deltaNs : 0
        }
    }

    static func nsToMach(_ ns: UInt64) -> UInt64 {
        UInt64(Double(ns) / machTimebase)
    }

    static func machToNs(_ mach: UInt64) -> UInt64 {
        UInt64(Double(mach) * machTimebase)
    }
}
