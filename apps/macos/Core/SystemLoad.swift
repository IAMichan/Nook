import Foundation
import CoreGraphics
import IOKit.ps

/// What the Mac tells about its room for Nook's optional background work: reading the screen on a timer, thinking along
/// with a local model. Nook steps back while the Mac is hot, in Low Power Mode, on battery (more so when it runs low) or
/// busy with something heavy (a build that keeps every core full), so it never competes with what you are doing. Work you
/// ask for (a question, dictation) always runs. The readings are raw; `EnergyPolicy` decides what they mean and
/// `EnergyMonitor` keeps the result.
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
    static var isOnBattery: Bool { battery().onBattery }

    /// Where the power comes from and the internal battery's charge in percent (nil on a Mac without one), from one read
    /// of the power sources.
    static func battery() -> (onBattery: Bool, level: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        let onBattery = type.map { ($0 as String) == kIOPMBatteryPowerKey } ?? false
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = description[kIOPSMaxCapacityKey] as? Int, capacity > 0 else { continue }
            return (onBattery, Int((Double(current) / Double(capacity) * 100).rounded()))
        }
        return (onBattery, nil)
    }

    /// Seconds since the last keyboard or pointer input anywhere on the Mac.
    static var idleSeconds: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// The main display is asleep (the lid is closed, or the Mac dimmed it).
    static var isDisplayAsleep: Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// Every reading at once, for `EnergyPolicy`. `wasLowBattery` is the last reading's, so a low battery has to charge a
    /// little before it counts as fine again (`EnergySignals.isLowBattery`).
    static func signals(wasLowBattery: Bool = false) -> EnergySignals {
        let power = battery()
        return EnergySignals(lowPowerMode: isLowPowerMode, hot: isHot, busy: isBusy, onBattery: power.onBattery,
                             lowBattery: EnergySignals.isLowBattery(level: power.level, onBattery: power.onBattery,
                                                                    wasLow: wasLowBattery),
                             away: idleSeconds >= EnergySignals.awayAfter, displayAsleep: isDisplayAsleep)
    }
}
