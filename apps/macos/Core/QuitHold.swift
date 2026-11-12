import Foundation

/// Hold ⌘Q to quit (Settings › General, off by default): a quick ⌘Q shows "Hold ⌘Q to quit Nook" instead of quitting,
/// and holding it for `holdDuration` quits. Only the key is held up: Quit in the menu bar menu, a click on Quit in the
/// app menu, and macOS quitting Nook (logging out, restarting, an update) go straight to `applicationShouldTerminate`,
/// which this never sees (`QuitHoldMonitor` only looks at key events).
///
/// The timing, without AppKit, so it is tested without real key events (`QuitHoldTests`).
/// (apps/desktop/src/window/QuitHold.ts):
/// - A hold is proven by the key's auto-repeat, or by the key still being down when the time is up (`check`), so it
///   also works with key repeat turned off.
/// - Once held long enough, quitting waits until the key is released (a key-up, ⌘ let go, or no repeat for a quiet
///   while). Otherwise the repeats still coming would reach the app in front after Nook is gone, and ⌘Q would quit that
///   one too. It also means a "sessions are still working" question opens after you let go, not under your finger.
struct QuitHold: Equatable {
    /// How long ⌘Q has to be held.
    static let holdDuration: TimeInterval = 1.0
    /// After the last repeat, how long without one counts as released (when no key-up comes: macOS often sends none for
    /// a letter while ⌘ is down).
    static let releaseGrace: TimeInterval = 0.6
    /// A slow repeat rate can be longer than the grace: two of its intervals then.
    static let cadenceMultiplier: Double = 2

    enum Phase: Equatable {
        case idle
        /// ⌘Q is down since `since`; `lastRepeat` is its last auto-repeat, if any.
        case holding(since: Date, lastRepeat: Date?)
        /// Held long enough: quits when the key is released.
        case armed(lastRepeat: Date, cadence: TimeInterval)
    }

    enum Input: Equatable {
        /// ⌘Q went down (not a repeat).
        case pressed
        /// An auto-repeat of ⌘Q.
        case repeated
        /// Q went up, or ⌘ was let go.
        case released
        /// Another key, or ⌘Q with another modifier.
        case otherKey
        /// The time asked for in `Output.checkAt` came. `keyDown`: whether Q is still down, if that can be read.
        case check(keyDown: Bool?)
    }

    enum Hint: Equatable {
        /// "Hold ⌘Q to quit Nook".
        case hold
        /// "Release to quit Nook".
        case release
        case hidden
    }

    struct Output: Equatable {
        /// The hint to show now; nil leaves it as it is.
        var hint: Hint?
        var quit = false
        /// When to call `handle(.check)` next; nil for no new time.
        var checkAt: Date?
    }

    private(set) var phase: Phase = .idle

    var isIdle: Bool { phase == .idle }

    /// How long without a repeat counts as released, for a key repeating every `cadence` seconds.
    static func quietPeriod(cadence: TimeInterval) -> TimeInterval {
        max(releaseGrace, cadence * cadenceMultiplier)
    }

    mutating func handle(_ input: Input, at now: Date) -> Output {
        switch (phase, input) {
        case (.idle, .pressed), (.holding, .pressed):
            // A fresh press while holding means its key-up never came: start over.
            phase = .holding(since: now, lastRepeat: nil)
            return Output(hint: .hold, checkAt: now.addingTimeInterval(Self.holdDuration))

        case (.holding(let since, let last), .repeated):
            guard now.timeIntervalSince(since) >= Self.holdDuration else {
                phase = .holding(since: since, lastRepeat: now)
                return Output()
            }
            return arm(at: now, cadence: now.timeIntervalSince(last ?? since))

        case (.holding(let since, let last), .check(let keyDown)):
            guard now.timeIntervalSince(since) >= Self.holdDuration else {
                return Output(checkAt: since.addingTimeInterval(Self.holdDuration))
            }
            // Still down by the key's own state, or (when that cannot be read) still repeating: held. Neither: it was let
            // go without a key-up.
            let repeating = last.map { now.timeIntervalSince($0) < Self.releaseGrace } ?? false
            if keyDown ?? repeating {
                return arm(at: now, cadence: 0)
            }
            phase = .idle
            return Output(hint: .hidden)

        case (.holding, .released), (.holding, .otherKey):
            phase = .idle
            return Output(hint: .hidden)

        case (.armed(_, let cadence), .repeated):
            phase = .armed(lastRepeat: now, cadence: cadence)
            return Output(checkAt: now.addingTimeInterval(Self.quietPeriod(cadence: cadence)))

        case (.armed, .released):
            phase = .idle
            return Output(hint: .hidden, quit: true)

        case (.armed(let last, let cadence), .check(let keyDown)):
            let quiet = Self.quietPeriod(cadence: cadence)
            if keyDown == true {
                // Still held (key repeat off, or repeats not reaching Nook): wait for the release.
                return Output(checkAt: now.addingTimeInterval(quiet))
            }
            guard now.timeIntervalSince(last) >= quiet else {
                return Output(checkAt: last.addingTimeInterval(quiet))
            }
            phase = .idle
            return Output(hint: .hidden, quit: true)

        case (.armed, .pressed), (.armed, .otherKey):
            // Held long enough already: another key does not take that back; the quit still waits for the release.
            return Output()

        case (.idle, _):
            return Output()
        }
    }

    private mutating func arm(at now: Date, cadence: TimeInterval) -> Output {
        phase = .armed(lastRepeat: now, cadence: max(0, cadence))
        return Output(hint: .release, checkAt: now.addingTimeInterval(Self.quietPeriod(cadence: max(0, cadence))))
    }
}
