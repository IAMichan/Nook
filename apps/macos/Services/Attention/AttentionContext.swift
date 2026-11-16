import Foundation

/// What Nook knows about you right now, read in one place and shared by everything that decides whether to speak up:
/// how long since your last key or click, whether the screen is locked, the app in front, a meeting, a share, a
/// recording and the quiet hours. The presence bands (looking, at the Mac, nearby, stepping away, away) are defined
/// here once; Think Along, the moments, the session focus, the screen reader, the connectors, the energy plan and the
/// phone pushes all read them instead of each asking macOS with a threshold of its own.
///
/// The quiet timer (`AppModel+Quiet`, every two seconds) refreshes it; a reader that needs the idle time to the second
/// reads it fresh on a Mac (`AttentionSignals.current()`), with the rest from the last refresh. Foundation only, so the
/// decisions can be tested; tested in AttentionContextTests.
struct AttentionContext: Equatable, Sendable {
    /// How present you are, from the time since your last input.
    enum Presence: Int, Comparable, Sendable {
        /// Input within `focusedWithin`: you are looking at the screen.
        case focused
        /// Within `presentWithin`: at the Mac.
        case present
        /// Within `nearbyWithin`: maybe reading, maybe gone.
        case nearby
        /// Within `awayAfter`: probably stepped away.
        case stepping
        /// `awayAfter` or longer, or the screen is locked.
        case away

        static func < (lhs: Presence, rhs: Presence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// You look at the screen: Nook does not tell you what the window in front shows already (`SessionFocus`).
    static let focusedWithin: TimeInterval = 60
    /// You are at the Mac: Think Along may look, the phone is not needed, the moments count you as active.
    static let presentWithin: TimeInterval = 120
    /// The screen reader still reads what is on screen.
    static let nearbyWithin: TimeInterval = 180
    /// Away: background reads that only keep the screen current wait, and a stretch of work ends.
    static let awayAfter: TimeInterval = 300

    var at = Date.distantPast
    /// Seconds since the last key press, click or pointer move anywhere on the Mac.
    var idle: TimeInterval = 0
    /// The screen is locked.
    var locked = false
    /// The bundle ID of the app in front; empty when unknown or Nook itself.
    var frontApp = ""
    /// In a meeting as quiet mode reads it: a call app or meeting site with the microphone open, or the calendar when
    /// that choice reads it (`QuietPolicy.isMeeting`).
    var meeting = false
    /// An event in your calendar is going on (not an all-day one), whatever quiet mode reads (`QuietPolicy.inEvent`).
    var inEvent = false
    /// You share your screen.
    var sharing = false
    /// Nook records a call.
    var recording = false
    /// Inside the quiet hours (`NoticeRules.quietHours`).
    var quietHours = false
    /// Quiet mode keeps Nook silent now (a share or a meeting with "quiet" chosen for it).
    var silent = false

    init(at: Date = .distantPast, idle: TimeInterval = 0, locked: Bool = false, frontApp: String = "") {
        self.at = at
        self.idle = idle
        self.locked = locked
        self.frontApp = frontApp
    }

    static func presence(idle: TimeInterval, locked: Bool) -> Presence {
        if locked || idle >= awayAfter { return .away }
        if idle < focusedWithin { return .focused }
        if idle < presentWithin { return .present }
        if idle < nearbyWithin { return .nearby }
        return .stepping
    }

    var presence: Presence { Self.presence(idle: idle, locked: locked) }

    /// At the Mac: input within `presentWithin`, the screen not locked.
    var isPresent: Bool { presence <= .present }
    /// Away: no input for `awayAfter`, or the screen is locked.
    var isAway: Bool { presence == .away }
    /// The screen is worth reading: input within `nearbyWithin`, the screen not locked.
    var readsScreen: Bool { presence <= .nearby }
    /// Not at the Mac, for the phone: no input for `presentWithin`, or the screen is locked. At the desk the Mac's own
    /// notices are enough.
    var awayFromMac: Bool { !isPresent }

    /// A call app is in front (`AppCatalog`).
    var callInFront: Bool { AppCatalog.isCallApp(frontApp) }
    /// In a meeting by any sign: quiet mode's reading, an event going on, a call app in front, or Nook recording a call.
    var inMeeting: Bool { meeting || inEvent || callInFront || recording }
    /// Nothing Nook starts by himself that is only nice to have (a moment, an offer): in a meeting, sharing your screen,
    /// inside the quiet hours or while quiet mode keeps him silent.
    var keepsNiceToHaveQuiet: Bool { inMeeting || sharing || quietHours || silent }

    /// The same context with a fresh reading of the input and the lock, the rest as it was.
    func refreshed(idle: TimeInterval, locked: Bool, frontApp: String? = nil, at now: Date) -> AttentionContext {
        var copy = self
        copy.idle = max(0, idle)
        copy.locked = locked
        if let frontApp { copy.frontApp = frontApp }
        copy.at = now
        return copy
    }
}

/// The last `AttentionContext`, shared across threads: the quiet timer writes it, every reader takes a copy.
final class AttentionNow: @unchecked Sendable {
    static let shared = AttentionNow()

    private let lock = NSLock()
    private var value = AttentionContext()

    var context: AttentionContext {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Changes the context in place.
    func update(_ change: (inout AttentionContext) -> Void) {
        lock.lock()
        change(&value)
        lock.unlock()
    }
}
