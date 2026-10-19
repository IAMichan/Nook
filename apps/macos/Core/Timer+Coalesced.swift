import Foundation

extension Timer {
    /// A repeating timer that the system may fire up to 20% late. Nook's timers are housekeeping, not frame-accurate, and
    /// the slack lets macOS batch their wake-ups with other work so the CPU stays idle longer.
    @discardableResult
    static func scheduledCoalesced(withTimeInterval interval: TimeInterval, block: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true, block: block)
        timer.tolerance = interval * 0.2
        return timer
    }
}
