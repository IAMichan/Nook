import Foundation

/// Reads `AttentionContext` on a Mac: the input and the lock fresh from the window server (`SystemLoad`, the one place
/// that asks macOS), the meeting, share and quiet hours from the quiet timer's last refresh (`AttentionNow`).
enum AttentionSignals {
    /// The shared context with the time since your last input and the lock read now. Two cheap calls; safe off the main
    /// thread.
    static func current(now: Date = Date()) -> AttentionContext {
        AttentionNow.shared.context.refreshed(idle: SystemLoad.idleSeconds, locked: SystemLoad.isScreenLocked, at: now)
    }
}
