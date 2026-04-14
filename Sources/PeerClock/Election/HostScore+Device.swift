import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension HostScore {
    /// Gather current device state into a HostScore.
    public static func current(
        localPeerID: UUID,
        incumbent: Bool = false,
        manualPin: Bool = false
    ) -> HostScore {
        return HostScore(
            manualPin: manualPin ? 1 : 0,
            incumbent: incumbent ? 1 : 0,
            powerConnected: detectPowerConnected() ? 1 : 0,
            thermalOK: detectThermalOK() ? 1 : 0,
            deviceTier: detectDeviceTier(),
            stablePeerID: localPeerID
        )
    }

    private static func detectPowerConnected() -> Bool {
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return state == .charging || state == .full
        #else
        return true  // assume power on macOS
        #endif
    }

    private static func detectThermalOK() -> Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .nominal || state == .fair
    }

    private static func detectDeviceTier() -> Int {
        // 0 = unknown, 1 = phone, 2 = tablet, 3 = laptop/desktop
        #if canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return 1
        case .pad: return 2
        default: return 0
        }
        #else
        return 3
        #endif
    }
}
