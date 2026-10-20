import Foundation

/// What Nook does while you share your screen or sit in a meeting (Settings › Notifications › Meetings and screen
/// sharing). The signals are read by `QuietWatch`; deciding what they mean lives here, so it can be tested without a Mac.
enum QuietBehavior: String, CaseIterable, Codable, Identifiable {
    /// Nothing changes.
    case normal
    /// No pop-ups of his own: no notices, suggestions, moments, track announcements or sounds. What you open yourself
    /// still works.
    case quiet
    /// Quiet, and the notch is left out of what you share: you still see Nook, the people watching do not.
    case hideFromShare
    /// Quiet, and the notch hides until it is over. A shortcut or the menu bar still opens it.
    case hide

    var id: String { rawValue }

    /// The choices for a meeting: leaving the notch out of a share only means something while you share.
    static let meetingChoices: [QuietBehavior] = [.normal, .quiet, .hide]

    var titleKey: String { "quiet.behavior.\(rawValue)" }
}

/// What is going on right now.
struct QuietSituation: Equatable {
    var sharing = false
    var meeting = false
}

/// How the notch behaves right now.
struct QuietState: Equatable {
    /// No pop-ups, announcements or sounds Nook starts by himself.
    var silent = false
    /// Left out of screen sharing and recordings.
    var excludedFromCapture = false
    /// The notch hides while it rests.
    var hidden = false
    /// Why, for the line in Settings.
    var situation = QuietSituation()

    static let normal = QuietState()
}

enum QuietPolicy {
    /// The state for what is going on and what you chose; sharing and a meeting at once take the strongest of both.
    static func state(for situation: QuietSituation, sharing: QuietBehavior, meeting: QuietBehavior) -> QuietState {
        var behaviors: [QuietBehavior] = []
        if situation.sharing { behaviors.append(sharing) }
        if situation.meeting { behaviors.append(meeting) }
        var state = QuietState(situation: situation)
        for behavior in behaviors {
            switch behavior {
            case .normal:
                break
            case .quiet:
                state.silent = true
            case .hideFromShare:
                state.silent = true
                state.excludedFromCapture = true
            case .hide:
                state.silent = true
                state.excludedFromCapture = true
                state.hidden = true
            }
        }
        return state
    }

    // MARK: Screen sharing

    /// A window on screen, as the window server lists it. The name is only known with the Screen Recording permission.
    struct Window: Equatable {
        var owner: String
        var bundleID: String?
        var name: String
        var height: Double

        init(owner: String, bundleID: String? = nil, name: String, height: Double) {
            self.owner = owner
            self.bundleID = bundleID
            self.name = name
            self.height = height
        }
    }

    /// Call apps whose sharing bar or picker says "share" in its window name (Zoom's "zoom share toolbar window",
    /// Teams' "Sharing control bar", Webex's sharing bar).
    static let sharingCallApps: [String] = ["zoom", "teams", "webex", "slack", "discord", "facetime", "whereby", "around", "gather"]
    /// Words for "sharing" in such a bar, in the languages these apps are used in.
    static let sharingWords: [String] = ["share", "sharing", "deelt", "delen", "gedeeld", "teilt", "freigabe", "freigeben",
                                         "partage", "compartiendo", "compartir"]
    /// Browsers: while a site shares your screen they show a small bar ("meet.google.com is sharing your screen.").
    static let browsers: [String] = ["chrome", "chromium", "edge", "brave", "arc", "vivaldi", "opera", "firefox", "safari", "orion", "zen"]
    /// The sentence in that bar, in the browser's language.
    static let browserSharingPhrases: [String] = ["is sharing", "sharing your screen", "sharing a window", "sharing this tab",
                                                  "deelt je scherm", "deelt een venster", "deelt dit tabblad", "deelt uw scherm",
                                                  "bildschirm frei", "fenster frei", "teilt", "partage", "compartiendo", "comparte"]
    /// macOS' own recording controls (⇧⌘5, a screen recording in progress).
    static let systemRecorders: [String] = ["screencaptureui"]

    /// A sharing bar is small (in points); a full browser window titled "File sharing tips" is not one.
    static let barMaxHeight: Double = 160

    /// Does any of these windows say your screen is being shared or recorded?
    static func isSharing(_ windows: [Window]) -> Bool {
        windows.contains(where: isSharingWindow)
    }

    static func isSharingWindow(_ window: Window) -> Bool {
        let owner = (window.owner + " " + (window.bundleID ?? "")).lowercased()
        let name = window.name.lowercased()
        if systemRecorders.contains(where: { owner.contains($0) }) { return true }
        // A sharing bar is small: a Slack window on the channel "#file-sharing" is not one.
        guard !name.isEmpty, window.height <= barMaxHeight else { return false }
        if browsers.contains(where: { owner.contains($0) }) {
            return browserSharingPhrases.contains(where: { name.contains($0) })
        }
        if sharingCallApps.contains(where: { owner.contains($0) }) {
            return sharingWords.contains(where: { name.contains($0) })
        }
        return false
    }

    // MARK: Meetings

    /// An event in your calendar.
    struct Event: Equatable {
        var start: Date
        var end: Date
    }

    /// Apps you hold calls in, by bundle ID; while one of them has the microphone open, you are in a call.
    static let callApps: Set<String> = ["us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp",
                                        "com.cisco.webex.meetings", "com.apple.FaceTime", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
                                        "co.teamport.around", "com.skype.skype", "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram",
                                        "com.gather.Gather"]
    /// Browsers by bundle ID prefix (their helpers, which hold the microphone, share it).
    static let browserBundles: [String] = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser",
                                           "com.vivaldi.Vivaldi", "com.operasoftware", "org.mozilla.firefox", "com.apple.Safari",
                                           "com.apple.WebKit", "com.kagi.kagimacOS", "app.zen-browser", "org.chromium.Chromium"]

    static func isCallApp(_ bundleID: String) -> Bool {
        callApps.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    static func isBrowser(_ bundleID: String) -> Bool {
        browserBundles.contains { bundleID.hasPrefix($0) }
    }

    /// The signals of a meeting.
    struct MeetingSignals: Equatable {
        var now = Date()
        /// Calendar events around now; only counted when `useCalendar` is on.
        var events: [Event] = []
        var useCalendar = true
        /// Apps that have the microphone open right now, by bundle ID (Nook itself left out).
        var microphoneApps: [String] = []
        /// Names of the windows on screen: a meeting site in a browser ("Meet – Weekly sync").
        var windowNames: [String] = []
        /// Nook is recording a call itself.
        var recording = false
    }

    /// Browser window names that are a meeting on the web.
    static let meetingSites: [String] = ["google meet", "meet.google.com", "meet - ", "microsoft teams", "teams.microsoft.com",
                                         "zoom meeting", "app.zoom.us", "whereby", "jitsi", "around.co", "webex"]

    static func isMeetingSite(_ windowName: String) -> Bool {
        let name = windowName.lowercased()
        return meetingSites.contains(where: { name.contains($0) })
    }

    /// In a meeting: Nook recording a call, a call app with the microphone open (being in front is not enough: Teams and
    /// Slack are also where you chat), a browser with the microphone open while a meeting site is on screen, or an event
    /// going on in your calendar. All-day events (a holiday, someone's birthday) are not meetings.
    static func isMeeting(_ signals: MeetingSignals) -> Bool {
        if signals.recording { return true }
        if signals.microphoneApps.contains(where: isCallApp) { return true }
        if signals.microphoneApps.contains(where: isBrowser), signals.windowNames.contains(where: isMeetingSite) { return true }
        guard signals.useCalendar else { return false }
        return signals.events.contains {
            $0.start <= signals.now && $0.end > signals.now && $0.end.timeIntervalSince($0.start) < 12 * 3600
        }
    }
}
