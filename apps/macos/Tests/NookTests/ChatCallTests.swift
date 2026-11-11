import XCTest

final class ChatCallTests: XCTestCase {
    func testPhoneDigits() {
        XCTAssertEqual(ChatCalls.phoneDigits("+31 6 1234 5678"), "+31612345678")
        XCTAssertEqual(ChatCalls.phoneDigits("0031-6-12345678"), "+31612345678")
        XCTAssertEqual(ChatCalls.phoneDigits("31612345678@s.whatsapp.net"), "+31612345678")
        XCTAssertNil(ChatCalls.phoneDigits("anna@example.com"))
        XCTAssertNil(ChatCalls.phoneDigits("@anna"))
        XCTAssertNil(ChatCalls.phoneDigits("123"))
    }

    func testEveryCallingAppHasALaunch() {
        for app in ChatCalls.callingApps {
            XCTAssertNotNil(ChatCalls.launch(.voice, for: ChatCallPerson(app: app, name: "Anna")), app)
        }
        for app in ["mail", "gmail", "outlook", "linkedin", "custom"] {
            XCTAssertNil(ChatCalls.launch(.voice, for: ChatCallPerson(app: app, name: "Anna")), app)
        }
    }

    func testDirectLinks() {
        let messages = ChatCalls.launch(.video, for: ChatCallPerson(app: "messages", name: "Anna", phone: "+31 6 12345678"))
        XCTAssertEqual(messages, .direct(URL(string: "facetime://+31612345678")!))
        let audio = ChatCalls.launch(.voice, for: ChatCallPerson(app: "messages", name: "Anna", email: "anna@example.com"))
        XCTAssertEqual(audio?.url?.absoluteString, "facetime-audio://anna@example.com")
        let teams = ChatCalls.launch(.video, for: ChatCallPerson(app: "teams", name: "Anna", email: "anna@contoso.com"))
        XCTAssertEqual(teams?.url?.absoluteString, "msteams:/l/call/0/0?users=anna@contoso.com&withVideo=true")
        XCTAssertEqual(ChatCalls.launch(.voice, for: ChatCallPerson(app: "skype", name: "Anna", username: "anna.b"))?.url?.absoluteString,
                       "skype:anna.b?call")
    }

    func testChatLinks() {
        let whatsApp = ChatCalls.launch(.voice, for: ChatCallPerson(app: "whatsapp", name: "Anna", phone: "+31612345678"))
        XCTAssertEqual(whatsApp, .chat(URL(string: "whatsapp://send?phone=31612345678")!))
        let telegram = ChatCalls.launch(.voice, for: ChatCallPerson(app: "telegram", name: "Anna", username: "@anna"))
        XCTAssertEqual(telegram?.url?.absoluteString, "tg://resolve?domain=anna")
        XCTAssertEqual(ChatCalls.launch(.voice, for: ChatCallPerson(app: "signal", name: "Anna", phone: "+31612345678"))?.url?.absoluteString,
                       "sgnl://signal.me/#p/+31612345678")
        XCTAssertEqual(ChatCalls.launch(.voice, for: ChatCallPerson(app: "whatsapp", name: "Anna")), .app)
    }

    func testGroups() {
        XCTAssertEqual(ChatCalls.launch(.video, for: ChatCallPerson(app: "whatsapp", name: "Team", isGroup: true)), .app)
        XCTAssertNil(ChatCalls.launch(.video, for: ChatCallPerson(app: "messages", name: "Team", isGroup: true)))
    }

    func testHoldsMicrophone() {
        XCTAssertTrue(ChatCalls.holdsMicrophone(["com.hnc.Discord"], microphoneApps: ["com.hnc.Discord.helper"]))
        XCTAssertFalse(ChatCalls.holdsMicrophone(["com.hnc.Discord"], microphoneApps: ["com.hnc.DiscordCanary"]))
    }

    func testTrackerPhases() {
        let start = Date(timeIntervalSince1970: 1000)
        var tracker = ChatCallTracker(started: start)
        XCTAssertTrue(tracker.observe(inCall: false, at: start.addingTimeInterval(10)))
        XCTAssertEqual(tracker.phase, .calling)
        XCTAssertTrue(tracker.observe(inCall: true, at: start.addingTimeInterval(20)))
        XCTAssertEqual(tracker.phase, .live(since: start.addingTimeInterval(20)))
        XCTAssertTrue(tracker.observe(inCall: true, at: start.addingTimeInterval(80)))
        // A short gap is no end.
        XCTAssertTrue(tracker.observe(inCall: false, at: start.addingTimeInterval(83)))
        XCTAssertEqual(tracker.phase, .live(since: start.addingTimeInterval(20)))
        XCTAssertTrue(tracker.observe(inCall: false, at: start.addingTimeInterval(90)))
        XCTAssertEqual(tracker.phase, .ended(duration: 60, at: start.addingTimeInterval(90)))
        XCTAssertTrue(tracker.observe(inCall: false, at: start.addingTimeInterval(93)))
        XCTAssertFalse(tracker.observe(inCall: false, at: start.addingTimeInterval(96)))
    }

    func testTrackerGivesUpWithoutACall() {
        let start = Date(timeIntervalSince1970: 0)
        var tracker = ChatCallTracker(started: start)
        XCTAssertFalse(tracker.observe(inCall: false, at: start.addingTimeInterval(ChatCallTracker.connectWait + 1)))
    }

    func testClock() {
        XCTAssertEqual(ChatCallTracker.clock(247), "4:07")
        XCTAssertEqual(ChatCallTracker.clock(3753), "1:02:33")
    }

    func testCommonGroups() {
        var group = InboxThread(id: "g1", app: "whatsapp", name: "Lead")
        group.kind = .group
        group.members = ["Arjan", "Noah", ChatMembership.me]
        var other = InboxThread(id: "g2", app: "telegram", name: "Lead")
        other.kind = .group
        other.members = ["Arjan"]
        var person = InboxThread(id: "p1", app: "whatsapp", name: "Arjan")
        person.kind = .person
        let found = ChatCommonGroups.groups(with: "arjan", app: "whatsapp", in: [group, other, person])
        XCTAssertEqual(found.map(\.id), ["g1"])
    }
}
