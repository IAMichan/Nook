import XCTest

/// The Nook tab on the phone as on the Mac (`CompanionNookChats.swift`, `CompanionFeature.nookChats`).
final class CompanionNookChatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    /// Monday 23 November 2026, 15:00 in Amsterdam.
    private let now = Date(timeIntervalSince1970: 1_795_442_400)

    private func chat(_ id: String, hoursAgo: Double, pinned: Bool? = nil, unread: Bool? = nil, busy: Bool = false,
                      waiting: Bool = false, scheduled: Bool? = nil, title: String = "", preview: String = "") -> ChatDigest {
        ChatDigest(id: id, title: title.isEmpty ? id : title, updated: now.timeIntervalSince1970 - hoursAgo * 3600, busy: busy,
                   waiting: waiting, preview: preview, pinned: pinned, unread: unread, scheduled: scheduled)
    }

    // MARK: Actions

    func testAnActionCarriesWhatItNeeds() {
        XCTAssertTrue(NookChatAction(kind: .rename, text: "Trip").isComplete)
        XCTAssertFalse(NookChatAction(kind: .rename, text: "   ").isComplete)
        XCTAssertFalse(NookChatAction(kind: .rename).isComplete)
        XCTAssertFalse(NookChatAction(kind: .rename, text: String(repeating: "a", count: 201)).isComplete)
        XCTAssertTrue(NookChatAction(kind: .pin, value: false).isComplete)
        XCTAssertFalse(NookChatAction(kind: .pin).isComplete)
        XCTAssertFalse(NookChatAction(kind: .archive).isComplete)
        XCTAssertFalse(NookChatAction(kind: .markUnread).isComplete)
        XCTAssertTrue(NookChatAction(kind: .delete).isComplete)
        XCTAssertTrue(NookChatAction(kind: .retry).isComplete)
    }

    func testOnlyArchivingDeletingAndRetryingWaitForTheAnswer() {
        XCTAssertEqual(Set(NookChatAction.Kind.allCases.filter { NookChatAction(kind: $0).needsIdle }), [.archive, .delete, .retry])
    }

    func testAnActionTravelsAsItsFixtureSays() throws {
        let json = #"{"id":"A","sent":1,"op":"chatAct","conversation":"C1","nookAction":{"kind":"pin","value":true}}"#
        let request = try JSONDecoder().decode(CompanionRequest.self, from: Data(json.utf8))
        XCTAssertEqual(request.op, .chatAct)
        XCTAssertEqual(request.nookAction, NookChatAction(kind: .pin, value: true))
    }

    // MARK: The list

    func testTheDigestOfAnOlderMacReadsWithoutTheFlags() throws {
        let json = #"{"id":"C","title":"T","updated":1,"busy":false,"waiting":false,"preview":"P"}"#
        let digest = try JSONDecoder().decode(ChatDigest.self, from: Data(json.utf8))
        XCTAssertNil(digest.pinned)
        XCTAssertNil(digest.queued)
        XCTAssertFalse(NookChatSections.asksAttention(digest))
    }

    func testAgeGroupsFollowTheMac() {
        XCTAssertEqual(NookChatSections.group(for: now.addingTimeInterval(60), now: now, calendar: calendar), .today)
        XCTAssertEqual(NookChatSections.group(for: now.addingTimeInterval(-3600 * 14), now: now, calendar: calendar), .today)
        XCTAssertEqual(NookChatSections.group(for: now.addingTimeInterval(-3600 * 20), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(NookChatSections.group(for: now.addingTimeInterval(-3600 * 24 * 5), now: now, calendar: calendar), .previousWeek)
        XCTAssertEqual(NookChatSections.group(for: now.addingTimeInterval(-3600 * 24 * 30), now: now, calendar: calendar), .older)
    }

    func testWhatAsksForYouGoesOnTopThenPinnedThenByAge() {
        let chats = [
            chat("busy", hoursAgo: 0, busy: true),
            chat("pin", hoursAgo: 200, pinned: true),
            chat("new", hoursAgo: 1, unread: true),
            chat("plan", hoursAgo: 2, waiting: true),
            chat("today", hoursAgo: 3),
            chat("yesterday", hoursAgo: 20),
            chat("week", hoursAgo: 24 * 4),
            chat("old", hoursAgo: 24 * 40),
        ]
        let sections = NookChatSections.sections(chats, searching: false, now: now, calendar: calendar)
        XCTAssertEqual(sections.attention.map(\.id), ["busy", "new", "plan"])
        XCTAssertEqual(sections.groups.map(\.group), [.pinned, .today, .yesterday, .previousWeek, .older])
        XCTAssertEqual(sections.groups.map { $0.chats.map(\.id) }, [["pin"], ["today"], ["yesterday"], ["week"], ["old"]])
    }

    func testAScheduledRunShowsOnlyWhenItAsksPinnedOrSearched() {
        let chats = [chat("run", hoursAgo: 1, scheduled: true), chat("asking", hoursAgo: 1, unread: true, scheduled: true),
                     chat("kept", hoursAgo: 1, pinned: true, scheduled: true)]
        let list = NookChatSections.sections(chats, searching: false, now: now, calendar: calendar)
        XCTAssertEqual(list.attention.map(\.id), ["asking"])
        XCTAssertEqual(list.groups.flatMap { $0.chats.map(\.id) }, ["kept"])
        let found = NookChatSections.sections(chats, searching: true, now: now, calendar: calendar)
        XCTAssertEqual(found.groups.flatMap { $0.chats.map(\.id) }, ["kept", "run"])
    }

    func testASearchMatchesEveryWordIgnoringCaseAndAccents() {
        let trip = chat("a", hoursAgo: 1, title: "Café in Rome", preview: "Book the table")
        XCTAssertTrue(NookChatSections.matches(trip, query: "cafe ROME"))
        XCTAssertTrue(NookChatSections.matches(trip, query: "table"))
        XCTAssertTrue(NookChatSections.matches(trip, query: "  "))
        XCTAssertFalse(NookChatSections.matches(trip, query: "rome paris"))
    }

    // MARK: Copy

    func testACopiedConversationReadsAsTheMacWritesIt() {
        let lines = [
            ChatLine(id: "1", fromNook: false, text: "What is on today?", date: 0, streaming: false, status: "", failed: false, onMac: false),
            ChatLine(id: "2", fromNook: true, text: "", date: 0, streaming: true, status: "Looking", failed: false, onMac: false),
            ChatLine(id: "3", fromNook: true, text: "Lunch with Anna.", date: 0, streaming: false, status: "", failed: false, onMac: false),
        ]
        XCTAssertEqual(NookChatExport.markdown(title: "Today", lines: lines, you: "You"),
                       "# Today\n\n**You**\n\nWhat is on today?\n\n**Nook**\n\nLunch with Anna.")
    }

    // MARK: Scopes

    func testTheNewOpsNeedNooksChat() {
        XCTAssertEqual(CompanionScopes.table[.chatAct], .scope(.nookChat))
        XCTAssertEqual(CompanionScopes.table[.chatSearch], .scope(.nookChat))
        XCTAssertTrue(CommandReceipts.keeps(.chatAct))
        XCTAssertFalse(CommandReceipts.keeps(.chatSearch))
        XCTAssertTrue(CompanionFeature.all.contains(CompanionFeature.nookChats))
    }

    func testAPhoneWithoutNooksChatSeesNoFoundConversations() {
        var response = CompanionResponse(id: "x", ok: true)
        response.conversationsFound = [chat("a", hoursAgo: 1)]
        response.conversationsArchived = 3
        let redacted = CompanionScopes.redact(response, granted: [.read])
        XCTAssertNil(redacted.conversationsFound)
        XCTAssertNil(redacted.conversationsArchived)
    }
}
