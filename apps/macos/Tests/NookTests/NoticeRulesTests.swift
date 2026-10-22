import XCTest

/// What one notice does (`NoticeRules`): every source follows its own way of showing, an app switched off stays quiet,
/// a meeting holds everything back except what an agent waits on, and the choices from before the rules carry over.
final class NoticeRulesTests: XCTestCase {
    func testEachSourceShowsTheWayItIsSet() {
        var rules = NoticeRules()
        XCTAssertEqual(rules.decide(.agents), .show(.card))
        XCTAssertEqual(rules.decide(.chats, app: "whatsapp"), .show(.card))
        XCTAssertEqual(rules.decide(.nook), .show(.card))
        XCTAssertEqual(rules.decide(.suggestions), .show(.strip))

        rules.setStyle(.system, for: .chats)
        rules.setStyle(.off, for: .nook)
        XCTAssertEqual(rules.decide(.chats, app: "whatsapp"), .show(.system))
        XCTAssertEqual(rules.decide(.nook), .historyOnly)
        XCTAssertEqual(rules.decide(.agents), .show(.card))
    }

    func testAChoiceEqualToTheDefaultIsNotStored() {
        var rules = NoticeRules()
        rules.setStyle(.strip, for: .agents)
        rules.setStyle(.card, for: .agents)
        rules.set(.agents, app: "codex", on: false)
        rules.set(.agents, app: "codex", on: true)
        XCTAssertEqual(rules, NoticeRules())
    }

    func testAnAppSwitchedOffStaysQuiet() {
        var rules = NoticeRules()
        rules.set(.agents, app: "codex", on: false)
        XCTAssertEqual(rules.decide(.agents, app: "Codex"), .historyOnly)
        XCTAssertEqual(rules.decide(.agents, app: "claude"), .show(.card))
        // Chat apps that show their own notifications are off until switched on.
        XCTAssertEqual(rules.decide(.chats, app: "telegram"), .historyOnly)
        rules.set(.chats, app: "telegram", on: true)
        XCTAssertEqual(rules.decide(.chats, app: "telegram"), .show(.card))
    }

    func testWhatAnAgentWaitsOnAlwaysReachesYou() {
        var rules = NoticeRules()
        rules.setStyle(.off, for: .agents)
        rules.set(.agents, app: "claude", on: false)
        XCTAssertEqual(rules.decide(.agents, app: "claude", urgent: true, quiet: true), .show(.card))
        rules.setStyle(.strip, for: .agents)
        XCTAssertEqual(rules.decide(.agents, urgent: true), .show(.card))
        rules.setStyle(.system, for: .agents)
        XCTAssertEqual(rules.decide(.agents, urgent: true), .show(.system))
    }

    func testQuietAndWatchingHoldBackTheRest() {
        let rules = NoticeRules()
        for source in NoticeSource.allCases {
            XCTAssertEqual(rules.decide(source, app: "whatsapp", quiet: true), .historyOnly)
            XCTAssertEqual(rules.decide(source, app: "whatsapp", watching: true), .historyOnly)
        }
    }

    func testOnlyASourceShownAsMacNotificationsAsksMacOS() {
        var rules = NoticeRules()
        XCTAssertFalse(rules.usesSystem)
        rules.setStyle(.system, for: .suggestions)
        XCTAssertTrue(rules.usesSystem)
    }

    func testTheEarlierChoicesCarryOver() {
        XCTAssertEqual(NoticeRules.migrated(agentNotice: nil, noticeDelivery: nil, whatsAppNotify: nil), NoticeRules())
        XCTAssertEqual(NoticeRules.migrated(agentNotice: "compact", noticeDelivery: "notch", whatsAppNotify: nil).style(for: .agents), .strip)
        XCTAssertEqual(NoticeRules.migrated(agentNotice: "compact", noticeDelivery: "system", whatsAppNotify: nil).style(for: .agents), .system)
        let rules = NoticeRules.migrated(agentNotice: nil, noticeDelivery: nil, whatsAppNotify: false,
                                         thinkAlongMuted: ["com.apple.Safari"])
        XCTAssertFalse(rules.isOn(.chats, app: "whatsapp"))
        XCTAssertFalse(rules.isOn(.suggestions, app: "com.apple.Safari"))
        XCTAssertTrue(rules.isOn(.suggestions, app: "com.apple.Notes"))
    }

    func testTheRulesSurviveBeingStored() throws {
        var rules = NoticeRules()
        rules.setStyle(.system, for: .agents)
        rules.set(.chats, app: "slack", on: true)
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode(NoticeRules.self, from: data), rules)
    }
}
