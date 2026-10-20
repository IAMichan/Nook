import XCTest

/// How Nook behaves while you share your screen or sit in a meeting (`QuietPolicy`): what the choices mean, how a
/// sharing bar is told apart from an ordinary window, and what counts as a meeting. All of it pure: the windows, the
/// microphone and the calendar come from the test.
final class QuietModeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Choices

    func testNothingGoingOnChangesNothing() {
        let state = QuietPolicy.state(for: QuietSituation(), sharing: .hide, meeting: .hide)
        XCTAssertEqual(state, .normal)
    }

    func testEachChoiceGoesFurtherThanTheLastOne() {
        let sharing = QuietSituation(sharing: true, meeting: false)
        XCTAssertFalse(QuietPolicy.state(for: sharing, sharing: .normal, meeting: .hide).silent)

        let quiet = QuietPolicy.state(for: sharing, sharing: .quiet, meeting: .normal)
        XCTAssertTrue(quiet.silent)
        XCTAssertFalse(quiet.excludedFromCapture)
        XCTAssertFalse(quiet.hidden)

        let unseen = QuietPolicy.state(for: sharing, sharing: .hideFromShare, meeting: .normal)
        XCTAssertTrue(unseen.silent)
        XCTAssertTrue(unseen.excludedFromCapture)
        XCTAssertFalse(unseen.hidden)

        let hidden = QuietPolicy.state(for: sharing, sharing: .hide, meeting: .normal)
        XCTAssertTrue(hidden.silent && hidden.excludedFromCapture && hidden.hidden)
    }

    func testSharingDuringAMeetingTakesTheStrongerChoice() {
        let both = QuietSituation(sharing: true, meeting: true)
        let state = QuietPolicy.state(for: both, sharing: .hideFromShare, meeting: .hide)
        XCTAssertTrue(state.hidden)
        XCTAssertEqual(state.situation, both)
        // Only the meeting choice applies when you are not sharing.
        let meeting = QuietPolicy.state(for: QuietSituation(sharing: false, meeting: true), sharing: .hide, meeting: .quiet)
        XCTAssertTrue(meeting.silent)
        XCTAssertFalse(meeting.hidden)
    }

    func testAMeetingCannotOnlyLeaveTheShare() {
        XCTAssertFalse(QuietBehavior.meetingChoices.contains(.hideFromShare))
        XCTAssertEqual(Set(QuietBehavior.allCases.map(\.titleKey)).count, QuietBehavior.allCases.count)
    }

    // MARK: Screen sharing

    func testSharingBarsOfCallAppsAndBrowsersCount() {
        XCTAssertTrue(QuietPolicy.isSharing([.init(owner: "zoom.us", bundleID: "us.zoom.xos", name: "zoom share toolbar window", height: 52)]))
        XCTAssertTrue(QuietPolicy.isSharing([.init(owner: "Microsoft Teams", name: "Sharing control bar", height: 60)]))
        XCTAssertTrue(QuietPolicy.isSharing([.init(owner: "Google Chrome", bundleID: "com.google.Chrome",
                                                   name: "meet.google.com is sharing your screen.", height: 48)]))
        XCTAssertTrue(QuietPolicy.isSharing([.init(owner: "Google Chrome", name: "meet.google.com deelt je scherm.", height: 48)]))
        XCTAssertTrue(QuietPolicy.isSharing([.init(owner: "Arc", bundleID: "company.thebrowser.Browser",
                                                   name: "meet.google.com gibt Ihren Bildschirm frei.", height: 48)]))
    }

    func testTheMacOSRecorderCountsEvenWithoutAWindowName() {
        XCTAssertTrue(QuietPolicy.isSharing([.init(owner: "screencaptureui", name: "", height: 24)]))
    }

    func testTheScreenshotToolCanBeLeftOut() {
        let tool = QuietPolicy.Window(owner: "screencaptureui", name: "", height: 24)
        XCTAssertFalse(QuietPolicy.isSharing([tool], countSystemCapture: false))
        // A real share still counts.
        XCTAssertTrue(QuietPolicy.isSharing([tool, .init(owner: "Microsoft Teams", name: "Sharing control bar", height: 60)],
                                            countSystemCapture: false))
    }

    func testOrdinaryWindowsDoNotCount() {
        // A full browser window about sharing, a Slack channel with "sharing" in its name, an unnamed window.
        XCTAssertFalse(QuietPolicy.isSharing([.init(owner: "Safari", name: "File sharing is sharing done right", height: 900)]))
        XCTAssertFalse(QuietPolicy.isSharing([.init(owner: "Slack", name: "file-sharing (Channel) - Acme - Slack", height: 820)]))
        XCTAssertFalse(QuietPolicy.isSharing([.init(owner: "zoom.us", name: "", height: 40)]))
        XCTAssertFalse(QuietPolicy.isSharing([.init(owner: "Finder", name: "Shared", height: 40)]))
        XCTAssertFalse(QuietPolicy.isSharing([]))
    }

    // MARK: Meetings

    func testACallAppWithTheMicrophoneIsAMeeting() {
        var signals = QuietPolicy.MeetingSignals(now: now)
        signals.useCalendar = false
        XCTAssertFalse(QuietPolicy.isMeeting(signals))
        signals.microphoneApps = ["us.zoom.xos"]
        XCTAssertTrue(QuietPolicy.isMeeting(signals))
        // Helpers of a call app share its bundle ID.
        signals.microphoneApps = ["com.microsoft.teams2.helper"]
        XCTAssertTrue(QuietPolicy.isMeeting(signals))
    }

    func testDictatingInAnotherAppIsNoMeeting() {
        var signals = QuietPolicy.MeetingSignals(now: now)
        signals.microphoneApps = ["com.apple.VoiceMemos"]
        XCTAssertFalse(QuietPolicy.isMeeting(signals))
    }

    func testABrowserCountsOnlyWithAMeetingSiteOnScreen() {
        var signals = QuietPolicy.MeetingSignals(now: now)
        signals.microphoneApps = ["com.google.Chrome.helper"]
        signals.windowNames = ["Inbox - Gmail"]
        XCTAssertFalse(QuietPolicy.isMeeting(signals))
        signals.windowNames = ["Meet - abc-defg-hij"]
        XCTAssertTrue(QuietPolicy.isMeeting(signals))
        // A meeting site without the microphone open is just a tab.
        signals.microphoneApps = []
        XCTAssertFalse(QuietPolicy.isMeeting(signals))
    }

    func testRecordingACallIsAMeeting() {
        var signals = QuietPolicy.MeetingSignals(now: now)
        signals.recording = true
        XCTAssertTrue(QuietPolicy.isMeeting(signals))
    }

    func testAnEventGoingOnCountsOnlyWhenYouWantItTo() {
        var signals = QuietPolicy.MeetingSignals(now: now)
        signals.events = [QuietPolicy.Event(start: now.addingTimeInterval(-600), end: now.addingTimeInterval(1200))]
        XCTAssertTrue(QuietPolicy.isMeeting(signals))
        signals.useCalendar = false
        XCTAssertFalse(QuietPolicy.isMeeting(signals))
    }

    func testAllDayAndLaterEventsAreNoMeeting() {
        var signals = QuietPolicy.MeetingSignals(now: now)
        signals.events = [
            QuietPolicy.Event(start: now.addingTimeInterval(-3600 * 10), end: now.addingTimeInterval(3600 * 14)),
            QuietPolicy.Event(start: now.addingTimeInterval(600), end: now.addingTimeInterval(1800)),
            QuietPolicy.Event(start: now.addingTimeInterval(-1800), end: now),
        ]
        XCTAssertFalse(QuietPolicy.isMeeting(signals))
    }
}
