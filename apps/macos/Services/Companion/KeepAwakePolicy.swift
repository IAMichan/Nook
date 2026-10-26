import Foundation

/// When Nook keeps the Mac awake, so the iPhone companion can reach it away from home (docs/COMPANION.md, "Keeping the
/// Mac awake"). A Mac that sleeps drops its connection to the relay and to Tailscale just as one that is off.
/// Foundation only, so the rules are tested on Linux; `KeepAwake` holds the power assertions.
enum KeepAwakePolicy {
    enum Mode: String, CaseIterable, Sendable {
        case off
        /// While agents work or wait on you, a little after, and while a phone is connected live.
        case whileWorking
        /// Whenever the companion is on (on battery only while there is work or a phone).
        case always
    }

    /// What is held: nothing; no idle sleep (the screen may still turn off); or no sleep at all, which on the power
    /// adapter keeps a MacBook awake with its lid closed too.
    enum Hold: Equatable, Sendable { case none, idle, system }

    enum Reason: Equatable, Sendable { case working, phone, always }

    struct Decision: Equatable, Sendable {
        var hold: Hold
        var reason: Reason?

        static let none = Decision(hold: .none, reason: nil)
    }

    /// After the last work, the Mac stays awake this long, so an answer or a follow-up from the phone still finds it.
    static let grace: TimeInterval = 5 * 60
    /// On battery, below this charge (percent) the Mac is left to sleep.
    static let lowBattery = 20

    /// `busy`: agents work or wait on you, or did within `grace`. `battery` is nil on a Mac without one.
    static func decide(mode: Mode, busy: Bool, phoneConnected: Bool, onPower: Bool, battery: Int?) -> Decision {
        let reason: Reason?
        switch mode {
        case .off: reason = nil
        case .whileWorking: reason = busy ? .working : phoneConnected ? .phone : nil
        case .always: reason = busy ? .working : phoneConnected ? .phone : .always
        }
        guard let reason else { return .none }
        if onPower { return Decision(hold: .system, reason: reason) }
        // On battery: never when it runs low, and "always" only for work or a phone, not for an idle Mac.
        if let battery, battery < lowBattery { return .none }
        if reason == .always { return .none }
        return Decision(hold: .idle, reason: reason)
    }

    /// Whether a session keeps the Mac busy: it works, or waits for an approval or an answer you may give from the phone.
    static func isBusy(attention: String, waiting: Bool) -> Bool {
        waiting || ["working", "approval", "input"].contains(attention)
    }
}
