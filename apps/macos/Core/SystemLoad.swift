import Foundation

/// Whether the Mac has room for Nook's optional background work right now: reading the screen on a timer, thinking along
/// with a local model. Nook steps back while the Mac is hot, in Low Power Mode, or busy with something heavy (a build that
/// keeps every core full), so it never competes with what you are doing. Work you ask for (a question, dictation) always runs.
enum SystemLoad {
    /// The one-minute load average per core above which the Mac counts as busy: every core has more than enough to do.
    static let busyPerCore = 1.0

    static var isConstrained: Bool {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return true }
        switch info.thermalState {
        case .serious, .critical: return true
        default: break
        }
        return isBusy
    }

    /// The run queue is longer than the cores can serve (`getloadavg`, as `uptime` reports it).
    static var isBusy: Bool {
        var load = [Double](repeating: 0, count: 1)
        guard getloadavg(&load, 1) == 1 else { return false }
        return load[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount)) > busyPerCore
    }
}
