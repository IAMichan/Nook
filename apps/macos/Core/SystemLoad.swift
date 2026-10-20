import Foundation
import CoreGraphics
import IOKit.ps

/// What the Mac tells about its room for Nook's optional background work: reading the screen on a timer, thinking along
/// with a local model. Nook steps back while the Mac is hot, in Low Power Mode, on battery or busy with something heavy
/// (a build that keeps every core full), so it never competes with what you are doing. Work you ask for (a question,
/// dictation) always runs. The readings are raw; `EnergyPolicy` decides what they mean and `EnergyMonitor` keeps the result.
enum SystemLoad {
    /// The one-minute load average per core above which the Mac counts as busy: every core has more than enough to do.
    static let busyPerCore = 1.0

    /// Hot, saving power or busy: the Mac has no room for optional work right now.
    static var isConstrained: Bool {
        isLowPowerMode || isHot || isBusy
    }

    static var isLowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// The thermal state is serious or critical.
    static var isHot: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return true
        default: return false
        }
    }

    /// The run queue is longer than the cores can serve (`getloadavg`, as `uptime` reports it).
    static var isBusy: Bool {
        var load = [Double](repeating: 0, count: 1)
        guard getloadavg(&load, 1) == 1 else { return false }
        return load[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) > busyPerCore
    }

    /// Running on the battery (false on a desktop Mac and on a MacBook on the charger).
    static var isOnBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    /// Seconds since the last keyboard or pointer input anywhere on the Mac.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// The main display is asleep (the lid is closed, or the Mac dimmed it).
    static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Every reading at once, for `EnergyPolicy`.
    static func signals() -> EnergySignals {
        EnergySignals(lowPowerMode: isLowPowerMode, hot: isHot, busy: isBusy, onBattery: isOnBattery,
                      away: idleSeconds >= EnergySignals.awayAfter, displayAsleep: isDisplayAsleep)
    }
}
