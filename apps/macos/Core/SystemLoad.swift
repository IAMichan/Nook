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

    /// The one-minute load average, as `uptime` reports it (0 when it cannot be read).
    static var loadAverage: Double {
        var load = [Double](repeating: 0, count: 1)
        return getloadavg(&load, 1) == 1 ? load[0] : 0
    }

    /// The run queue is longer than the cores can serve (`getloadavg`, as `uptime` reports it).
    static var isBusy: Bool {
        var load = [Double](repeating: 0, count: 1)
        guard getloadavg(&load, 1) == 1 else { return false }
        return load[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) > busyPerCore
    }

    /// macOS's memory pressure level: 1 normal, 2 warning, 4 critical (`kern.memorystatus_vm_pressure_level`); 1 when it
    /// cannot be read.
    static var memoryPressureLevel: Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return level
    }

    /// Pages read back from swap since the Mac started (`vm_stat`'s "Swapins"); nil when it cannot be read. Two readings
    /// apart give the rate `EnergySignals.isMemoryTight` looks at.
    static var swapins: UInt64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.swapins : nil
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

    /// The login session's screen is locked (the lock screen or the screen saver with a password is up).
    static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// Every reading at once, for `EnergyPolicy`. `wasLowBattery` is the last reading's, so a low battery has to charge a
    /// little before it counts as fine again (`EnergySignals.isLowBattery`).
    /// `swapinsPerSecond` is the swap-in rate since the last reading (nil on the first).
    static func signals(wasLowBattery: Bool = false, swapinsPerSecond: Double? = nil) -> EnergySignals {
        let power = battery()
        return EnergySignals(lowPowerMode: isLowPowerMode, hot: isHot, busy: isBusy,
                             memoryTight: EnergySignals.isMemoryTight(pressureLevel: memoryPressureLevel,
                                                                      swapinsPerSecond: swapinsPerSecond),
                             onBattery: power.onBattery,
                             lowBattery: EnergySignals.isLowBattery(level: power.level, onBattery: power.onBattery,
                                                                    wasLow: wasLowBattery),
                             away: idleSeconds >= EnergySignals.awayAfter, displayAsleep: isDisplayAsleep,
                             screenLocked: isScreenLocked)
    }
}
