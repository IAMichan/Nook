import XCTest

/// WhatsApp through a local gateway: conversations in memory, what the gateways send, the webhook's signature, and who a
/// recipient means. Partly after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
final class WhatsAppTests: XCTestCase {
    private func message(_ id: String, chat: String, from: String? = nil, text: String = "hoi", at: Double = 0,
                         fromMe: Bool = false, mention: Bool = false, name: String = "Lisa") -> WAMessage {
        WAMessage(id: id, chat: chat, sender: from ?? chat, senderName: name, text: text,
                  date: Date(timeIntervalSince1970: 1_800_000_000 + at), fromMe: fromMe, mentionsMe: mention)
    }

    func testAMessageWithNothingToShowIsNoBubble() {
        var inbox = WAInbox()
        let group = "120363000000000001@g.us"
        XCTAssertEqual(inbox.add(message("1", chat: group, text: "\u{200B}"), filters: WAFilters()), .ignored)
        XCTAssertNil(inbox.conversations[group], "a reaction passed on as a message makes no chat and no bubble")
        var photo = message("2", chat: group, text: "")
        photo.media = .image
        XCTAssertNotEqual(inbox.add(photo, filters: WAFilters()), .ignored, "a photo without a caption is a message")
        XCTAssertEqual(inbox.conversations[group]?.messages.map(\.id), ["2"])
    }

    func testAGOWAReactionSentAsAMessageGoesOnItsMessage() {
        let nested = Data(#"{"event":"message","payload":{"id":"R1","chat_id":"120363000000000001@g.us","from":"31633333333@s.whatsapp.net","is_from_me":false,"body":"","reaction":{"message":"🙏","id":"POST1"}}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: nested),
                       .reaction(chat: "120363000000000001@g.us", message: "POST1", emoji: "🙏",
                                 sender: "31633333333@s.whatsapp.net", fromMe: false))
        let flat = Data(#"{"event":"message","payload":{"id":"R2","chat_id":"120363000000000001@g.us","from":"31633333333@s.whatsapp.net","reaction":"❤️","reacted_message_id":"POST1"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: flat),
                       .reaction(chat: "120363000000000001@g.us", message: "POST1", emoji: "❤️",
                                 sender: "31633333333@s.whatsapp.net", fromMe: false))
        let openwa = Data(#"{"event":"message.received","data":{"id":"R3","chatId":"120363000000000001@g.us","type":"reaction","body":""}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .openwa, body: openwa), .ignored)
    }

    func testInboxGroupsByChatAndCountsUnread() {
        var inbox = WAInbox()
        let filters = WAFilters()
        XCTAssertEqual(inbox.add(message("1", chat: "31600000001@s.whatsapp.net"), filters: filters), .notify)
        inbox.add(message("2", chat: "31600000001@s.whatsapp.net", at: 5), filters: filters)
        inbox.add(message("3", chat: "31600000002@s.whatsapp.net", at: 3), filters: filters)
        XCTAssertEqual(inbox.conversations.count, 2)
        XCTAssertEqual(inbox.conversations["31600000001@s.whatsapp.net"]?.unread, 2)
        XCTAssertEqual(inbox.sorted.first?.id, "31600000001@s.whatsapp.net")
        XCTAssertEqual(inbox.add(message("2", chat: "31600000001@s.whatsapp.net"), filters: filters), .duplicate)
        // The same person under another form is the same chat.
        XCTAssertEqual(inbox.add(message("4", chat: "31600000001:7@c.us", at: 9), filters: filters), .notify)
        XCTAssertEqual(inbox.conversations.count, 2)
        // Answering from the phone reads the chat.
        XCTAssertEqual(inbox.add(message("5", chat: "31600000002@s.whatsapp.net", at: 10, fromMe: true), filters: filters), .quiet)
        XCTAssertEqual(inbox.conversations["31600000002@s.whatsapp.net"]?.unread, 0)
    }

    /// "@open chat Jan" in the Mac app: a person's chat opens by their number; a group or a hidden id has no such link.
    func testAppLinkOpensAPersonsChatByNumber() {
        XCTAssertEqual(WAJID.appLink("31600000001@s.whatsapp.net")?.absoluteString, "whatsapp://send?phone=31600000001")
        XCTAssertEqual(WAJID.appLink("31600000001:12@s.whatsapp.net")?.absoluteString, "whatsapp://send?phone=31600000001")
        XCTAssertEqual(WAJID.appLink("31600000001@c.us")?.absoluteString, "whatsapp://send?phone=31600000001")
        XCTAssertNil(WAJID.appLink("120363001@g.us"))
        XCTAssertNil(WAJID.appLink("120363001@newsletter"))
        XCTAssertNil(WAJID.appLink("123456789@lid"))
        XCTAssertNil(WAJID.appLink("status@broadcast"))
        XCTAssertNil(WAJID.appLink("jan@s.whatsapp.net"))
    }

    func testStatusUpdatesAndChannelsStayQuietUntilAsked() {
        var inbox = WAInbox()
        XCTAssertEqual(WAJID.kind("status@broadcast"), .status)
        XCTAssertEqual(WAJID.kind("120363001@newsletter"), .channel)
        XCTAssertEqual(WAJID.kind("31600000001@s.whatsapp.net"), .person)
        XCTAssertEqual(inbox.add(message("s1", chat: "status@broadcast"), filters: WAFilters()), .quiet)
        XCTAssertEqual(inbox.add(message("c1", chat: "120363001@newsletter"), filters: WAFilters()), .quiet)
        XCTAssertTrue(inbox.visible(filters: WAFilters()).isEmpty)
        var loud = WAFilters()
        loud.muteStatus = false
        loud.muteChannels = false
        XCTAssertEqual(inbox.add(message("s2", chat: "status@broadcast", at: 1), filters: loud), .notify)
        XCTAssertEqual(inbox.add(message("c2", chat: "120363001@newsletter", at: 1), filters: loud), .notify)
        XCTAssertEqual(inbox.visible(filters: loud).count, 2)
    }

    func testEachChatCanBeLouderOrQuieterThanItsKind() {
        var inbox = WAInbox()
        var filters = WAFilters()
        // A group you care about reaches you without a mention; a person you muted never does, even with a mention.
        filters.setMode(.loud, for: "1@g.us")
        filters.setMode(.muted, for: "31600000002:3@c.us")
        XCTAssertEqual(filters.mode(for: "31600000002@s.whatsapp.net"), .muted)
        XCTAssertEqual(inbox.add(message("g1", chat: "1@g.us", from: "316@s.whatsapp.net"), filters: filters), .notify)
        XCTAssertEqual(inbox.add(message("p1", chat: "31600000002@s.whatsapp.net", mention: true), filters: filters), .quiet)
        XCTAssertEqual(inbox.visible(filters: filters).map(\.id), ["1@g.us"])
        // Back to automatic: the kind's rule applies again, and the choice leaves the table.
        filters.setMode(.automatic, for: "1@g.us")
        XCTAssertNil(filters.modes["1@g.us"])
        XCTAssertEqual(inbox.add(message("g2", chat: "1@g.us", from: "316@s.whatsapp.net", at: 2), filters: filters), .quiet)
    }

    func testGroupsStayQuietUnlessTheyMentionYou() {
        var inbox = WAInbox()
        let group = "120363000000000001@g.us"
        XCTAssertEqual(inbox.add(message("g1", chat: group, from: "316@s.whatsapp.net"), filters: WAFilters()), .quiet)
        XCTAssertTrue(inbox.visible(filters: WAFilters()).isEmpty)
        XCTAssertEqual(inbox.add(message("g2", chat: group, from: "316@s.whatsapp.net", mention: true), filters: WAFilters()), .notify)
        var filters = WAFilters()
        filters.ignored = ["31600000009@s.whatsapp.net"]
        XCTAssertEqual(inbox.add(message("i1", chat: "31600000009@s.whatsapp.net"), filters: filters), .ignored)
    }

    func testHistoryIsKeptButNeverNew() {
        var inbox = WAInbox()
        XCTAssertEqual(inbox.add(message("h1", chat: "1@s.whatsapp.net"), filters: WAFilters(), history: true), .quiet)
        XCTAssertEqual(inbox.conversations["1@s.whatsapp.net"]?.unread, 0)
        // More than a chat keeps: the oldest go, the newest stay.
        let count = WAInbox.keep + 5
        for index in 0..<count { inbox.add(message("m\(index)", chat: "1@s.whatsapp.net", at: Double(index + 1)), filters: WAFilters()) }
        XCTAssertEqual(inbox.conversations["1@s.whatsapp.net"]?.messages.count, WAInbox.keep)
        XCTAssertEqual(inbox.conversations["1@s.whatsapp.net"]?.messages.last?.id, "m\(count - 1)")
    }

    func testLoadingOlderMessagesBringsBackWhatAChatLetGo() {
        var inbox = WAInbox()
        let chat = "1@s.whatsapp.net"
        let count = WAInbox.keep + 5
        for index in 0..<count { inbox.add(message("m\(index)", chat: chat, at: Double(index + 1)), filters: WAFilters()) }
        XCTAssertEqual(inbox.conversations[chat]?.canLoadOlder, true, "full: older ones may exist")
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.id, "m5")

        XCTAssertEqual(inbox.growCapacity(chat), WAInbox.keep + WAInbox.olderStep)
        for index in 0..<count { inbox.add(message("m\(index)", chat: chat, at: Double(index + 1)), filters: WAFilters(), history: true) }
        XCTAssertEqual(inbox.conversations[chat]?.messages.count, count, "the five it let go are back")
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.id, "m0")
        XCTAssertEqual(inbox.conversations[chat]?.unread, count, "history never changes the unread count")

        inbox.markOldestReached(chat)
        XCTAssertEqual(inbox.conversations[chat]?.canLoadOlder, false)
    }

    func testAGroupKnownOnlyByItsIdIsAskedItsName() {
        let old = "31622360496-1542111077@g.us"
        XCTAssertTrue(WAJID.isPlaceholderName("Group 31622360496-1542111077", for: old), "the gateway's stand-in")
        XCTAssertTrue(WAJID.isPlaceholderName("", for: old))
        XCTAssertTrue(WAJID.isPlaceholderName(WAJID.displayNumber(old), for: old))
        XCTAssertTrue(WAJID.isPlaceholderName("120363000000000001@g.us", for: "120363000000000001@g.us"))
        XCTAssertFalse(WAJID.isPlaceholderName("Familie", for: old))
        XCTAssertTrue(WAJID.isPlaceholderName("+31 6 12345678, +31 6 87654321", for: old), "only the members' numbers")
        XCTAssertFalse(WAJID.isPlaceholderName("2024", for: old), "a short number is a name")
        XCTAssertFalse(WAJID.isPlaceholderName("🎉", for: old))
    }

    func testOpeningAGroupKeepsItsRealName() {
        let group = "31622360496-1542111077@g.us"
        var inbox = WAInbox()
        inbox.add(message("a", chat: group, from: "2@s.whatsapp.net"), filters: WAFilters(), name: "Familie")
        var history = message("b", chat: group, from: "3@s.whatsapp.net", at: 1)
        history.chatName = "Group 31622360496-1542111077"
        inbox.add(history, filters: WAFilters(), history: true)
        XCTAssertEqual(inbox.conversations[group]?.name, "Familie", "the gateway's stand-in never replaces the real name")
        var renamed = message("c", chat: group, from: "3@s.whatsapp.net", at: 2)
        renamed.chatName = "Familie 2026"
        inbox.add(renamed, filters: WAFilters())
        XCTAssertEqual(inbox.conversations[group]?.name, "Familie 2026", "a real new name still comes through")
    }

    func testTheListOfYourGroupsNamesEveryGroupAtOnce() {
        let json = """
        {"code":"SUCCESS","results":{"data":[
          {"JID":"120363000000000001@g.us","Name":"Familie"},
          {"JID":"120363000000000002@g.us","Name":"","LinkedParentJID":"120363000000000003@g.us"},
          {"JID":"120363000000000003@g.us","Name":"Buurt","IsParent":true},
          {"JID":"120363000000000004@g.us","Name":""}
        ]}}
        """
        let names = WAGOWA.groupNames(Data(json.utf8))
        XCTAssertEqual(names["120363000000000001@g.us"], "Familie")
        XCTAssertEqual(names["120363000000000002@g.us"], "Buurt", "a community's announcement group takes its community's name")
        XCTAssertNil(names["120363000000000004@g.us"])
        XCTAssertTrue(WAGOWA.groupNames(Data("{}".utf8)).isEmpty)
    }

    func testGOWAFindsHomebrewsFFmpeg() {
        XCTAssertEqual(WAGOWA.searchPath("/usr/bin:/bin:/usr/sbin:/sbin"),
                       "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
        XCTAssertEqual(WAGOWA.searchPath("/opt/homebrew/bin:/usr/bin"), "/opt/homebrew/bin:/usr/bin:/usr/local/bin")
        XCTAssertEqual(WAGOWA.searchPath(nil), "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    func testARefusedSendSaysWhyNotOnlyItsCode() {
        let refused = #"{"status":500,"code":"INTERNAL_SERVER_ERROR","message":"failed to create thumbnail exit status 1","results":null}"#
        XCTAssertEqual(WAGOWA.errorReason(Data(refused.utf8)), "failed to create thumbnail exit status 1")
        let noFFmpeg = #"{"status":500,"code":"INTERNAL_SERVER_ERROR","message":"ffmpeg not installed","results":null}"#
        XCTAssertEqual(WAGOWA.errorReason(Data(noFFmpeg.utf8)), tr("whatsapp.gowa.needsFFmpeg"), "says how to get ffmpeg")
        XCTAssertEqual(WAGOWA.errorReason(Data(#"{"code":"DEVICE_ID_REQUIRED","message":" "}"#.utf8)), "DEVICE_ID_REQUIRED")
        XCTAssertNil(WAGOWA.errorReason(Data("<html>".utf8)))
    }

    func testOneGroupsInfoNamesItOrItsCommunity() {
        let flat = #"{"results":{"JID":"120363000000000001@g.us","Name":"Familie"}}"#
        XCTAssertEqual(WAGOWA.groupInfo(Data(flat.utf8)).name, "Familie")
        let wrapped = #"{"results":{"data":{"JID":"120363000000000002@g.us","Name":"","LinkedParentJID":"120363000000000003@g.us"}}}"#
        let info = WAGOWA.groupInfo(Data(wrapped.utf8))
        XCTAssertNil(info.name)
        XCTAssertEqual(info.parent, "120363000000000003@g.us", "an announcement group points at its community")
        XCTAssertNil(WAGOWA.groupInfo(Data("{}".utf8)).name)
    }

    func testVotesMoveTheirPollInsteadOfShowingAsMessages() {
        let group = "120363000000000001@g.us"
        let creation = WAPollData.gowa(["type": "creation", "poll_id": "P1", "question": "Lunch?",
                                        "options": [["name": "Pizza"], ["name": "Sushi"]], "selectable_options_count": 1])
        XCTAssertEqual(creation.poll, WAPoll(question: "Lunch?", options: ["Pizza", "Sushi"]))
        var inbox = WAInbox()
        var poll = message("P1", chat: group, text: "")
        poll.poll = creation.poll
        inbox.add(poll, filters: WAFilters(), history: true)
        var vote = message("V1", chat: group, from: "316@s.whatsapp.net", text: "")
        vote.pollVote = WAPollData.gowa(["type": "vote", "poll_id": "P1", "selected_options": ["Sushi"]]).vote
        XCTAssertEqual(inbox.add(vote, filters: WAFilters()), .quiet)
        var mine = message("V2", chat: group, text: "", fromMe: true)
        mine.pollVote = WAPollVote(poll: "P1", choice: ["Sushi"])
        inbox.add(mine, filters: WAFilters())
        let shown = inbox.conversations[group]?.messages
        XCTAssertEqual(shown?.map(\.id), ["P1"], "a vote is no message of its own")
        XCTAssertEqual(shown?.first?.poll?.chatPoll.options, [
            ChatPoll.Option(text: "Pizza", votes: 0, chosen: false, voters: []),
            ChatPoll.Option(text: "Sushi", votes: 2, chosen: true, voters: [tr("chat.poll.you"), WAJID.displayNumber("316@s.whatsapp.net")])
        ])
        var cleared = message("V3", chat: group, from: "316@s.whatsapp.net", text: "")
        cleared.pollVote = WAPollVote(poll: "P1", choice: [])
        inbox.add(cleared, filters: WAFilters())
        XCTAssertEqual(inbox.conversations[group]?.messages.first?.poll?.chatPoll.total, 1, "a cleared vote takes theirs back")
        XCTAssertTrue(WAPollData.isVoteText("Poll vote cleared"))
        XCTAssertTrue(WAPollData.isVoteText("Poll vote: Nee"))
        XCTAssertFalse(WAPollData.isVoteText("Poll: Lunch?"))
        XCTAssertEqual(WAPollData.openwa(["name": "Q", "options": ["a", "b"], "allowMultipleAnswers": true]),
                       WAPoll(question: "Q", options: ["a", "b"], multiple: true))
    }

    func testPollVotesAreKeptAcrossARestart() throws {
        let group = "120363000000000001@g.us"
        let lunch = WAPoll(question: "Lunch?", options: ["Pizza", "Sushi"])
        var poll = message("P1", chat: group, text: "")
        poll.poll = lunch
        var before = WAInbox()
        // Seen live: every vote from here on passes through Nook.
        before.add(poll, filters: WAFilters())
        var vote = message("V1", chat: group, from: "316@s.whatsapp.net", text: "")
        vote.pollVote = WAPollVote(poll: "P1", choice: ["Pizza"])
        before.add(vote, filters: WAFilters())
        before.applyVote(WAPollVote(poll: "P1", choice: ["Sushi"]), chat: group, voter: WAPoll.me)
        XCTAssertEqual(before.pollLedger["P1"]?.complete, true)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("nook-poll-votes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        WAPollStore.save(before.pollLedger, to: file)
        let loaded = WAPollStore.load(from: file)
        XCTAssertEqual(loaded, before.pollLedger.pruned())

        // After the restart the poll comes back from GOWA's own database, which keeps no votes.
        var after = WAInbox(polls: loaded)
        var stored = poll
        stored.poll?.counted = false
        after.add(stored, filters: WAFilters(), history: true)
        let shown = try XCTUnwrap(after.conversations[group]?.messages.first?.poll?.chatPoll)
        XCTAssertTrue(shown.counted, "seen live before the restart: its counts are complete")
        XCTAssertEqual(shown.options.map(\.votes), [1, 1])
        XCTAssertEqual(shown.chosen, ["Sushi"])

        // An empty ledger leaves no file behind (WhatsApp turned off).
        after.clear()
        XCTAssertTrue(after.pollLedger.isEmpty)
        WAPollStore.save(after.pollLedger, to: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAVoteOnAPollNookDoesNotShowYetIsKeptForIt() throws {
        let group = "120363000000000001@g.us"
        var inbox = WAInbox()
        XCTAssertNil(inbox.applyVote(WAPollVote(poll: "P2", choice: ["Ja"]), chat: group, voter: "316@s.whatsapp.net"))
        var poll = message("P2", chat: group, text: "")
        poll.poll = WAPoll(question: "Mee?", options: ["Ja", "Nee"])
        inbox.add(poll, filters: WAFilters(), history: true)
        let shown = try XCTUnwrap(inbox.conversations[group]?.messages.first?.poll?.chatPoll)
        XCTAssertFalse(shown.counted, "from history: votes from before may be missing")
        XCTAssertTrue(shown.partial, "the vote Nook saw still shows")
        XCTAssertEqual(shown.options.map(\.votes), [1, 0])

        // Without any known vote such a poll shows no counts, as before.
        var empty = message("P3", chat: group, text: "")
        empty.poll = WAPoll(question: "Waar?", options: ["Hier"])
        inbox.add(empty, filters: WAFilters(), history: true)
        let quiet = try XCTUnwrap(inbox.conversations[group]?.messages.first { $0.id == "P3" }?.poll?.chatPoll)
        XCTAssertFalse(quiet.counted)
        XCTAssertFalse(quiet.partial)
    }

    func testOldPollVotesAreForgotten() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var ledger = WAPollLedger()
        ledger.record(WAPollVote(poll: "old", choice: ["a"]), voter: "1", at: now.addingTimeInterval(-WAPollLedger.maxAge - 1))
        for index in 0..<(WAPollLedger.limit + 5) {
            ledger.record(WAPollVote(poll: "P\(index)", choice: ["a"]), voter: "1", at: now.addingTimeInterval(-Double(index)))
        }
        let pruned = ledger.pruned(now: now)
        XCTAssertNil(pruned["old"])
        XCTAssertEqual(pruned.polls.count, WAPollLedger.limit)
        XCTAssertNotNil(pruned["P0"], "the most recently touched stay")
        XCTAssertNil(pruned["P\(WAPollLedger.limit)"])
    }

    func testPollVotersAreNamedAsTheGroupKnowsThem() {
        let group = "120363000000000001@g.us"
        var conversation = WAConversation(id: group, name: "Club", isGroup: true, lastActivity: Date())
        conversation.members = [WAMember(ids: ["123@lid", "31600000001@s.whatsapp.net"], name: "Anna")]
        var written = message("M1", chat: group, from: "31600000002@s.whatsapp.net", name: "Bram")
        written.chat = group
        conversation.messages = [written]
        var poll = WAPoll(question: "Lunch?", options: ["Pizza", "Sushi"])
        poll.votes = ["123@lid": ["Pizza"], "31600000002@s.whatsapp.net": ["Pizza", "Sushi"], WAPoll.me: ["Sushi"],
                      "31699999999@s.whatsapp.net": ["Sushi"]]
        var names = WAMemberIndex(conversation)
        let shown = poll.chatPoll { names.name($0) }
        XCTAssertEqual(shown.options[0].voters, ["Anna", "Bram"], "by the name the gateway gives, else the one they wrote under")
        XCTAssertEqual(shown.options[1].voters, [tr("chat.poll.you"), "Bram", WAJID.displayNumber("31699999999@s.whatsapp.net")],
                       "you first, someone unknown by their number")
        XCTAssertEqual(shown.options.map(\.votes), [2, 3])
        XCTAssertTrue(shown.namesVoters)
    }

    func testAnOpenedChatFetchesItsMessagesAgainNotOnlyOnce() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(WAInbox.historyDue(last: nil, now: now))
        XCTAssertFalse(WAInbox.historyDue(last: now.addingTimeInterval(-5), now: now), "opened twice in a row: fetched once")
        XCTAssertTrue(WAInbox.historyDue(last: now.addingTimeInterval(-86_400), now: now), "opened yesterday: fetched again")
        XCTAssertTrue(WAInbox.historyDue(last: now.addingTimeInterval(3_600), now: now), "the clock was set back")

        // Yesterday's history is kept; today's poll the live feed missed comes in with the next fetch.
        let group = "120363000000000001@g.us"
        var inbox = WAInbox()
        inbox.add(message("Y1", chat: group, at: -86_400), filters: WAFilters(), history: true)
        var poll = message("P1", chat: group, text: "")
        poll.poll = WAPoll(question: "Lunch?", options: ["Pizza", "Sushi"])
        let fetched = [message("Y1", chat: group, at: -86_400), poll]
        for message in fetched { inbox.add(message, filters: WAFilters(), history: true) }
        let kept = inbox.conversations[group]?.messages ?? []
        XCTAssertEqual(WAInbox.newest(fetched, kept, limit: 20).map(\.id), ["Y1", "P1"])
        XCTAssertEqual(inbox.conversations[group]?.unread, 0, "fetched history counts as read")
    }

    func testPollsGOWAKeepsOutOfTheHistoryComeFromItsOwnDatabase() {
        let group = "120363000000000001@g.us"
        XCTAssertTrue(WAGOWAStoredPolls.pollsSQL(chats: [group], limit: 20).contains("chat_jid IN ('\(group)')"))
        XCTAssertTrue(WAGOWAStoredPolls.sendersSQL(ids: ["it's"]).contains("'it''s'"), "quotes are escaped")

        let rows: [[String: Any]] = [
            ["id": "P1", "chat": group, "question": "Lunch?", "options": #"[{"name":"Pizza","hash":"a"},{"name":"Sushi","hash":"b"}]"#,
             "selectable": 1, "created": "2027-01-15 09:00:00.5+01:00"],
            ["id": "P2", "chat": group, "question": "Wanneer?", "options": #"[{"name":"Ma"},{"name":"Di"}]"#,
             "selectable": 0, "created": "2027-01-15 10:00:00 +0000 UTC"],
            ["id": "", "chat": group, "question": "No id", "options": "[]", "selectable": 1, "created": "2027-01-15 09:00:00"],
        ]
        let polls = WAGOWAStoredPolls.polls(rows)
        XCTAssertEqual(polls.map(\.id), ["P1", "P2"])
        XCTAssertEqual(polls.first?.poll, WAPoll(question: "Lunch?", options: ["Pizza", "Sushi"], counted: false))
        XCTAssertEqual(polls.last?.poll.multiple, true, "0 is any number of answers")
        XCTAssertEqual(polls.first?.date, Date(timeIntervalSince1970: 1_800_000_000 + 0.5), "09:00 at +01:00 is 08:00 UTC")
        XCTAssertEqual(polls.last?.date, Date(timeIntervalSince1970: 1_800_000_000 + 7_200))
        XCTAssertEqual(WAGOWAStoredPolls.date("2027-01-15T08:00:00Z"), Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertNil(WAGOWAStoredPolls.date("gisteren"))

        // Who sent it: yours by your number or your @lid, else the member with the name WhatsApp has for them.
        let senders: [[String: Any]] = [
            ["id": "P1", "sender": "31600000000@s.whatsapp.net", "name": ""],
            ["id": "P2", "sender": "4242@lid", "name": "Anna"],
        ]
        let device: [String: Any] = ["jid": "31600000000:12@s.whatsapp.net", "lid": "999:12@lid"]
        let messages = WAGOWAStoredPolls.messages(polls, senders: senders, device: device)
        XCTAssertEqual(messages.map(\.fromMe), [true, false])
        XCTAssertEqual(messages.last?.senderName, "Anna")
        XCTAssertEqual(messages.last?.sender, "4242@lid")
        XCTAssertEqual(messages.first?.poll?.chatPoll.counted, false, "the votes before are not known: no counts")
        XCTAssertEqual(WAGOWAStoredPolls.messages(polls, senders: [], device: nil).first?.sender, group,
                       "without a sender the chat sent it")

        // Kept by Nook as any message, so it shows in the chat.
        var inbox = WAInbox()
        for message in messages { inbox.add(message, filters: WAFilters(), history: true) }
        XCTAssertEqual(inbox.conversations[group]?.messages.compactMap(\.poll?.question), ["Lunch?", "Wanneer?"])
    }

    func testGOWAVersionsCompareByNumber() {
        XCTAssertTrue(WAGOWARelease.isOlder("9.2.2", than: "9.3.0"))
        XCTAssertFalse(WAGOWARelease.isOlder("9.3.0", than: "9.3.0"))
        XCTAssertFalse(WAGOWARelease.isOlder("v9.10.1", than: "9.9.0"), "by number, not by text")
        XCTAssertTrue(WAGOWARelease.isOlder("9.6", than: "9.6.1"))
    }

    func testAnEditedPollIsNoNewPoll() {
        let body = Data(#"{"event":"message","payload":{"id":"E1","chat_id":"120363000000000001@g.us","body":"Poll edited: Lunch?","poll":{"type":"edit","poll_id":"P1","question":"Lunch?","options":[{"name":"Pizza"}]}}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: body), .ignored)
        let creation = Data(#"{"event":"message","payload":{"id":"P1","chat_id":"120363000000000001@g.us","body":"Poll: Lunch?","poll":{"type":"creation","poll_id":"P1","question":"Lunch?","options":[{"name":"Pizza"}]}}}"#.utf8)
        guard case .message(let parsed)? = WAWebhook.parse(kind: .gowa, body: creation) else { return XCTFail("no poll") }
        XCTAssertEqual(parsed.poll?.question, "Lunch?")
        XCTAssertEqual(parsed.text, "")
    }

    func testChannelsGetTheirNameAndPicture() {
        let channel = "120363173134535056@newsletter"
        XCTAssertTrue(WAJID.isPlaceholderName(WAJID.displayNumber(channel), for: channel), "a channel known only by its number")
        let gowa = Data(#"{"results":{"data":[{"id":"120363173134535056@newsletter","thread_metadata":{"name":{"text":"Tech News"},"preview":{"url":"","direct_path":"/v/t61/abc.jpg?x=1"}}}]}}"#.utf8)
        XCTAssertEqual(WAAvatar.gowaChannels(gowa), [WAChannel(jid: channel, name: "Tech News",
                                                                 picture: URL(string: "https://mmg.whatsapp.net/v/t61/abc.jpg?x=1"))])
        XCTAssertEqual(WAAvatar.openwaChannels(Data(#"[{"id":"1@newsletter","name":"Updates"}]"#.utf8)),
                       [WAChannel(jid: "1@newsletter", name: "Updates", picture: nil)])
    }

    func testChatPicturesOnlyFromWhatsApp() {
        let gowa = Data(#"{"code":"SUCCESS","results":{"url":"https://pps.whatsapp.net/v/t61/abc.jpg?oh=1","type":"preview"}}"#.utf8)
        XCTAssertEqual(WAAvatar.url(gowa)?.host, "pps.whatsapp.net")
        let openwa = Data(#"{"url":"https://pps.whatsapp.net/v/x.jpg"}"#.utf8)
        XCTAssertNotNil(WAAvatar.url(openwa))
        XCTAssertNil(WAAvatar.url(Data(#"{"url":null}"#.utf8)), "no picture, or hidden")
        XCTAssertNil(WAAvatar.url(Data(#"{"url":"https://evil.example/x.jpg"}"#.utf8)), "never another host")
        XCTAssertNil(WAAvatar.url(Data(#"{"url":"https://pps.whatsapp.net.evil.example/x.jpg"}"#.utf8)))
        XCTAssertNil(WAAvatar.url(Data(#"{"url":"http://pps.whatsapp.net/x.jpg"}"#.utf8)))
    }

    func testCatchUpAfterSleepIsKeptButNeverNew() {
        var inbox = WAInbox()
        let chat = "1@s.whatsapp.net"
        let woke = Date(timeIntervalSince1970: 1_800_000_000 + 100)
        // Written while the Mac slept (likely read on the phone): kept, not unread, not announced.
        XCTAssertEqual(inbox.add(message("old", chat: chat, at: 10), filters: WAFilters(), quietBefore: woke), .quiet)
        XCTAssertEqual(inbox.conversations[chat]?.unread, 0)
        XCTAssertEqual(inbox.conversations[chat]?.messages.count, 1)
        // A message written now still reaches you.
        XCTAssertEqual(inbox.add(message("new", chat: chat, at: 200), filters: WAFilters(), quietBefore: woke), .notify)
        XCTAssertEqual(inbox.conversations[chat]?.unread, 1)
    }

    func testRateLimit() {
        var limit = WARateLimit(limit: 2, window: 60)
        let now = Date()
        XCTAssertTrue(limit.allow(now: now))
        XCTAssertTrue(limit.allow(now: now))
        XCTAssertFalse(limit.allow(now: now.addingTimeInterval(10)))
        XCTAssertTrue(limit.allow(now: now.addingTimeInterval(61)))
    }

    // MARK: Webhook

    func testOnlyASignedDeliveryCounts() {
        let body = Data(#"{"event":"message","device_id":"31611111111@s.whatsapp.net","payload":{"id":"ABC","chat_id":"31622222222@s.whatsapp.net","from":"31622222222@s.whatsapp.net","from_name":"Jan","timestamp":"2026-10-18T12:00:00Z","is_from_me":false,"body":"Kom je vanavond?"}}"#.utf8)
        let signature = WAWebhook.signature(body: body, secret: "geheim")
        XCTAssertTrue(signature.hasPrefix("sha256="))
        XCTAssertTrue(WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": signature], body: body, secret: "geheim"))
        XCTAssertFalse(WAWebhook.verify(kind: .gowa, headers: ["x-hub-signature-256": signature], body: body, secret: "anders"))
        XCTAssertFalse(WAWebhook.verify(kind: .gowa, headers: [:], body: body, secret: "geheim"))
        XCTAssertFalse(WAWebhook.verify(kind: .openwa, headers: ["x-hub-signature-256": signature], body: body, secret: "geheim"))

        guard case .message(let parsed)? = WAWebhook.parse(kind: .gowa, body: body) else { return XCTFail("no message") }
        XCTAssertEqual(parsed.id, "ABC")
        XCTAssertEqual(parsed.senderName, "Jan")
        XCTAssertEqual(parsed.text, "Kom je vanavond?")
        XCTAssertFalse(parsed.fromMe)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: Data(#"{"event":"receipt"}"#.utf8)), .ignored)
        XCTAssertNil(WAWebhook.parse(kind: .gowa, body: Data("geen json".utf8)))
    }

    func testOpenWADelivery() {
        let body = Data(#"{"event":"message.received","sessionId":"s","data":{"id":"X1","from":"31633333333@c.us","chatId":"31633333333@c.us","body":"","type":"voice","timestamp":1800000000,"fromMe":false,"contact":{"pushName":"Sanne"}}}"#.utf8)
        guard case .message(let parsed)? = WAWebhook.parse(kind: .openwa, body: body) else { return XCTFail("no message") }
        XCTAssertEqual(parsed.media, .voice(seconds: nil))
        XCTAssertEqual(parsed.senderName, "Sanne")
    }

    func testTheWebhookRequestIsReadWhole() {
        let raw = "POST /whatsapp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 4\r\nX-Hub-Signature-256: sha256=ab\r\n\r\n"
        XCTAssertEqual(WAHTTPRequest.parse(Data((raw + "ab").utf8)), .incomplete)
        guard case .done(let request) = WAHTTPRequest.parse(Data((raw + "abcd").utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.path, "/whatsapp")
        XCTAssertEqual(request.headers["x-hub-signature-256"], "sha256=ab")
        XCTAssertEqual(request.body, Data("abcd".utf8))
    }

    // MARK: Recipients and text

    private let chats: [(jid: String, name: String)] = [
        ("31611111111@s.whatsapp.net", "Lisa de Vries"),
        ("31622222222@s.whatsapp.net", "Jan Bakker"),
        ("31633333333@s.whatsapp.net", "Jan Jansen"),
        ("120363000000000001@g.us", "Familie")
    ]

    func testRecipientByNameNumberOrId() {
        XCTAssertEqual(WhatsAppRecipients.match("Lisa", in: chats)?.jid, "31611111111@s.whatsapp.net")
        XCTAssertEqual(WhatsAppRecipients.match("lisa de vries", in: chats)?.jid, "31611111111@s.whatsapp.net")
        XCTAssertEqual(WhatsAppRecipients.match("familie", in: chats)?.jid, "120363000000000001@g.us")
        XCTAssertEqual(WhatsAppRecipients.match("06-11111111", in: chats)?.jid, "31611111111@s.whatsapp.net")
        XCTAssertEqual(WhatsAppRecipients.match("31622222222@c.us", in: chats)?.name, "Jan Bakker")
        XCTAssertNil(WhatsAppRecipients.match("Jan", in: chats), "two Jans: ask which one")
        XCTAssertEqual(WhatsAppRecipients.match("Bakker", in: chats)?.name, "Jan Bakker")
        XCTAssertNil(WhatsAppRecipients.match("0698765432", in: chats), "a number that is not a chat is never sent to")
        XCTAssertNil(WhatsAppRecipients.match("Pieter", in: chats))
    }

    func testMessagesAsText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let messages = [
            message("2", chat: "c", text: "Top, tot dan", at: 120, fromMe: true, name: ""),
            message("1", chat: "c", text: "Ben om 8 uur bij je", at: 0)
        ]
        let text = WhatsAppRecipients.lines(messages, chatName: "Lisa", calendar: calendar)
        XCTAssertEqual(text, "2027-01-15 08:00 Lisa: Ben om 8 uur bij je\n2027-01-15 08:02 Me: Top, tot dan")
        var voice = message("3", chat: "c", text: "")
        voice.media = .voice(seconds: 12)
        XCTAssertTrue(WhatsAppRecipients.lines([voice], chatName: "Lisa", calendar: calendar).hasSuffix("Lisa: [voice message]"))
    }

    func testAChatReadsTheGatewayHistoryTogetherWithWhatCameInLive() {
        let old = message("1", chat: "c", text: "Kun je de taak oppakken?", at: 0)
        let stored = message("2", chat: "c", text: "Bedankt!", at: 60, fromMe: true, name: "")
        var live = message("3", chat: "c", text: "Is Guard productie al klaar?", at: 30 * 86_400)
        live.reactions = [WAReaction(emoji: "👍", sender: "me", fromMe: true)]
        var keptStored = stored
        keptStored.receipt = .read
        let chat = WAInbox.newest([stored, old], [keptStored, live], limit: 20)
        XCTAssertEqual(chat.map(\.id), ["1", "2", "3"], "the live message the gateway's history lacks is the newest")
        XCTAssertEqual(chat[1].receipt, .read, "the kept copy, with its ticks, wins")
        XCTAssertEqual(WAInbox.newest([stored, old], [live], limit: 2).map(\.id), ["2", "3"])
    }

    func testGOWADownloadIsFetchedFromTheGatewayItself() {
        let answer = #"{"code":"SUCCESS","results":{"filename":"offerte.pdf","file_path":"statics/media/31612345678/2026-10-20/offerte.pdf","file_url":"http://localhost:3000/statics/media/31612345678/2026-10-20/offerte.pdf"}}"#
        let saved = WAGOWA.download(Data(answer.utf8))
        XCTAssertEqual(saved?.path, "/statics/media/31612345678/2026-10-20/offerte.pdf")
        XCTAssertEqual(saved?.name, "offerte.pdf")
        // Without a link, only a path under /statics counts.
        let pathOnly = #"{"results":{"file_path":"statics/media/a b.pdf"}}"#
        XCTAssertEqual(WAGOWA.download(Data(pathOnly.utf8))?.path, "/statics/media/a%20b.pdf")
        XCTAssertNil(WAGOWA.download(Data(#"{"results":{"file_path":"/etc/passwd"}}"#.utf8)))
    }

    func testOpenedFilesGetASafeName() {
        XCTAssertEqual(WAMedia.document(name: "Guard-meting (1).pdf").safeFileName(given: nil, mimeType: nil),
                       "Guard-meting (1).pdf")
        XCTAssertEqual(WAMedia.document(name: "../../evil/x.pdf").safeFileName(given: nil, mimeType: nil), "-..-evil-x.pdf")
        XCTAssertEqual(WAMedia.image.safeFileName(given: nil, mimeType: "image/jpeg"), "photo.jpeg")
        XCTAssertTrue(WAMedia.document(name: nil).isOpenable)
        XCTAssertFalse(WAMedia.location.isOpenable)
    }

    func testReceiptsMoveYourTicksForwardOnly() {
        var inbox = WAInbox()
        let filters = WAFilters()
        let chat = "31600000001@s.whatsapp.net"
        inbox.add(message("in", chat: chat), filters: filters)
        inbox.add(message("out", chat: chat, at: 5, fromMe: true), filters: filters)
        func ticks(_ id: String) -> WAReceipt? { inbox.conversations[chat]?.messages.first { $0.id == id }?.receipt }
        // A message you just sent is on the server: one tick. Theirs have none.
        XCTAssertEqual(ticks("out"), .sent)
        XCTAssertNil(ticks("in"))

        XCTAssertEqual(inbox.applyReceipt(.delivered, ids: ["out"], chat: "31600000001@c.us"), chat)
        XCTAssertEqual(ticks("out"), .delivered)
        XCTAssertEqual(inbox.applyReceipt(.read, ids: ["out"], chat: chat), chat)
        XCTAssertEqual(ticks("out"), .read)
        // A late "delivered" never takes the blue ticks back, and a receipt for their message changes nothing.
        XCTAssertNil(inbox.applyReceipt(.delivered, ids: ["out"], chat: chat))
        XCTAssertEqual(ticks("out"), .read)
        XCTAssertNil(inbox.applyReceipt(.read, ids: ["in"], chat: chat))
        XCTAssertNil(ticks("in"))
        // A chat named another way (no chat at all) is still found by the message's id.
        inbox.add(message("out2", chat: chat, at: 6, fromMe: true), filters: filters)
        XCTAssertEqual(inbox.applyReceipt(.delivered, ids: ["out2"], chat: ""), chat)

        // A receipt that beats its own message is kept for it.
        XCTAssertNil(inbox.applyReceipt(.delivered, ids: ["early"], chat: chat))
        inbox.add(message("early", chat: chat, at: 7, fromMe: true), filters: filters)
        XCTAssertEqual(ticks("early"), .delivered)
        // History without a status shows no ticks.
        inbox.add(message("old", chat: chat, at: 1, fromMe: true), filters: filters, history: true)
        XCTAssertNil(ticks("old"))
    }

    func testAGroupsTicksWaitForEveryMember() {
        var inbox = WAInbox()
        let group = "1203630@g.us"
        inbox.add(message("out", chat: group, at: 5, fromMe: true, name: ""), filters: WAFilters())
        inbox.add(message("in", chat: group, from: "31600000002@s.whatsapp.net", at: 6, name: "Jan"), filters: WAFilters())
        func sent() -> WAMessage? { inbox.conversations[group]?.messages.first { $0.id == "out" } }

        // Anna read it: she is listed, but the group's ticks wait while the members are not known.
        XCTAssertEqual(inbox.applyMemberReceipt(.read, ids: ["out"], chat: group, member: "31600000001@s.whatsapp.net"), group)
        XCTAssertEqual(sent()?.receipt, .sent)
        XCTAssertEqual(sent()?.readers.values.map(\.receipt), [.read])
        XCTAssertNil(inbox.applyMemberReceipt(.read, ids: ["in"], chat: group, member: "31600000001@s.whatsapp.net"),
                     "their message has no ticks")

        let anna = WAMember(ids: ["31600000001@s.whatsapp.net", "123@lid"], name: "Anna")
        let jan = WAMember(ids: ["31600000002@s.whatsapp.net"], name: "")
        XCTAssertTrue(inbox.setMembers([anna, jan], chat: group))
        XCTAssertEqual(sent()?.receipt, .sent, "Jan has not got it yet")
        XCTAssertEqual(inbox.applyMemberReceipt(.delivered, ids: ["out"], chat: group, member: "31600000002@c.us"), group)
        XCTAssertEqual(sent()?.receipt, .delivered, "everyone has it: two grey ticks")
        inbox.applyMemberReceipt(.read, ids: ["out"], chat: group, member: "31600000002@s.whatsapp.net")
        XCTAssertEqual(sent()?.receipt, .read, "everyone read it: two blue ticks")
        XCTAssertEqual(sent()?.readers.count, 2, "one person under two ways of writing their id stays one")

        let conversation = inbox.conversations[group]!
        XCTAssertEqual(conversation.memberName("123@lid"), "Anna")
        XCTAssertEqual(conversation.memberName("31600000002@s.whatsapp.net"), "Jan", "the name they wrote under")
        XCTAssertEqual(conversation.memberNames, ["Anna", "Jan"])
    }

    /// The member index gives the same names as matching every id one by one, which it replaced for speed.
    func testMemberIndexNamesLikeMatchingEveryId() {
        func written(_ sender: String, _ name: String, fromMe: Bool = false) -> WAMessage {
            WAMessage(id: UUID().uuidString, chat: "1@g.us", sender: sender, senderName: name, text: "hi",
                      media: .none, date: Date(), fromMe: fromMe)
        }
        var conversation = WAConversation(id: "1@g.us", name: "Groep", isGroup: true, lastActivity: Date())
        conversation.members = [
            WAMember(ids: ["31600000001@s.whatsapp.net", "123@lid"], name: "Anna"),
            WAMember(ids: ["31600000002@s.whatsapp.net"], name: ""),
            // Matches Jan's number too, but comes second: Jan's own (empty) entry wins and his written name is used.
            WAMember(ids: ["31600000002@c.us"], name: "Not Jan"),
            WAMember(ids: ["@beeper-user:beeper.com"], name: ""),
            WAMember(ids: ["31600000004:12@s.whatsapp.net"], name: ""),
        ]
        conversation.messages = [
            written("31600000002@s.whatsapp.net", "Jan old"),
            written("31600000002@c.us", "Jan"),
            written("@beeper-user:beeper.com", "Bee"),
            written("31600000004@s.whatsapp.net", ""),
            written("31600000005@s.whatsapp.net", "Mine", fromMe: true),
        ]
        // The rules as they were: the first member that matches, else the newest name written under the id, else the number.
        func expected(_ id: String) -> String {
            if let member = conversation.members?.first(where: { $0.matches(id) }), !member.name.isEmpty { return member.name }
            if let message = conversation.messages.last(where: {
                !$0.fromMe && WAJID.sameReactor($0.sender, id) && !$0.senderName.isEmpty
            }) { return message.senderName }
            return WAJID.displayNumber(id)
        }
        let ids = ["123@lid", "31600000001@c.us", "31600000002@s.whatsapp.net", "31600000002", "@beeper-user:beeper.com",
                   "31600000004@s.whatsapp.net", "31600000005@s.whatsapp.net", "999@lid", ""]
        var index = WAMemberIndex(conversation)
        for id in ids {
            XCTAssertEqual(index.name(id), expected(id), id)
        }
        XCTAssertEqual(conversation.memberNames, conversation.members!.map { $0.name.isEmpty ? expected($0.ids[0]) : $0.name })
        XCTAssertEqual(conversation.memberName("31600000002@s.whatsapp.net"), "Jan", "the newest name they wrote under")
    }

    func testGatewaysListAGroupsMembers() {
        let gowa = Data(#"{"code":"SUCCESS","results":{"JID":"1203630@g.us","Name":"Club","Participants":[{"JID":"123@lid","PhoneNumber":"31600000001@s.whatsapp.net","DisplayName":"Anna"},{"JID":"31699999999@s.whatsapp.net","DisplayName":""}]}}"#.utf8)
        let members = WAGOWA.members(gowa)
        XCTAssertEqual(members.map(\.name), ["Anna", ""])
        XCTAssertTrue(members[0].matches("31600000001@c.us"))
        XCTAssertEqual(WAMembers.others(members, me: "31699999999@s.whatsapp.net").map(\.name), ["Anna"], "you are left out")
        let openwa = WAMembers.list([["id": ["_serialized": "31600000001@c.us"], "isAdmin": true], "31600000002@c.us"])
        XCTAssertEqual(openwa.map(\.ids), [["31600000001@c.us"], ["31600000002@c.us"]])
        let listed = WAMembers.list(["items": [["id": "@me", "isSelf": true], ["id": "@jan", "fullName": "Jan"]]])
        XCTAssertEqual(listed.map(\.name), ["Jan"])
    }

    func testGatewayReceipts() {
        let gowa = Data(#"{"event":"message.ack","device_id":"31699999999@s.whatsapp.net","payload":{"ids":["A1","A2"],"chat_id":"31600000001@s.whatsapp.net","from":"31600000001@s.whatsapp.net","receipt_type":"read"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: gowa),
                       .receipt(ids: ["A1", "A2"], chat: "31600000001@s.whatsapp.net", status: .read))
        // Your own phone reading their messages moves no ticks: the chat is read, in a group too.
        let own = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"31600000001@s.whatsapp.net","receipt_type":"read-self"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: own), .readElsewhere(chat: "31600000001@s.whatsapp.net"))
        let ownGroup = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","receipt_type":"read-self"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: ownGroup), .readElsewhere(chat: "1203630@g.us"))
        // A group's receipt without a member says nothing; one with a member moves that member only.
        let group = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","receipt_type":"delivered"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: group), .ignored)
        let member = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","from":"31600000001@s.whatsapp.net in 1203630@g.us","receipt_type":"read"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: member),
                       .memberReceipt(ids: ["A1"], chat: "1203630@g.us", member: "31600000001@s.whatsapp.net", status: .read))
        let sender = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","sender_id":"123@lid","receipt_type":"delivered"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: sender),
                       .memberReceipt(ids: ["A1"], chat: "1203630@g.us", member: "123@lid", status: .delivered))

        let openwa = Data(#"{"event":"message.ack","sessionId":"s","data":{"id":"uuid-1","messageId":"B1","status":"delivered","ack":2,"chatId":"31600000001@c.us"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .openwa, body: openwa),
                       .receipt(ids: ["B1"], chat: "31600000001@c.us", status: .delivered))
        let failed = Data(#"{"event":"message.failed","data":{"messageId":"B2","status":"failed","ack":-1}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .openwa, body: failed), .receipt(ids: ["B2"], chat: "", status: .failed))

        XCTAssertEqual(WAReceipt.read.advanced(to: .delivered), .read)
        XCTAssertEqual(WAReceipt.read.advanced(to: .failed), .failed)
        XCTAssertNil(WAReceipt(status: "retry"))
    }

    /// An answer to a message carries what it answers, from the webhook and from the history of every gateway.
    func testRepliesKnowWhatTheyAnswer() {
        let gowa = Data(#"""
        {"event":"message","payload":{"id":"R1","chat_id":"316@s.whatsapp.net","from":"316@s.whatsapp.net","timestamp":"2026-10-20T09:00:00Z","body":"Ja!","replied_to_id":"Q1","quoted_body":"Eten om zes?"}}
        """#.utf8)
        guard case .message(let reply)? = WAWebhook.parse(kind: .gowa, body: gowa) else { return XCTFail("no message") }
        XCTAssertEqual(reply.replyTo, "Q1")
        XCTAssertEqual(reply.quotedText, "Eten om zes?")

        let openwa = Data(#"""
        {"event":"message.received","data":{"id":"R2","chatId":"316@c.us","from":"316@c.us","body":"Ja","type":"text","timestamp":1800000000,"quotedMessage":{"id":"Q2","body":"Kom je?"}}}
        """#.utf8)
        guard case .message(let other)? = WAWebhook.parse(kind: .openwa, body: openwa) else { return XCTFail("no message") }
        XCTAssertEqual(other.replyTo, "Q2")
        XCTAssertEqual(other.quotedText, "Kom je?")

        let history = WAGOWA.messages(Data(#"""
        {"results":{"data":[{"id":"R3","chat_jid":"316@s.whatsapp.net","sender_jid":"316@s.whatsapp.net","content":"Top","timestamp":"2026-10-20T09:00:00Z","context_metadata":"{\"replied_to_id\":\"Q3\"}","reactions":[{"emoji":"👍","sender_jid":"317@s.whatsapp.net","is_from_me":true}]}]}}
        """#.utf8), me: nil)
        XCTAssertEqual(history.first?.replyTo, "Q3")
        XCTAssertEqual(history.first?.reactions, [WAReaction(emoji: "👍", sender: "317@s.whatsapp.net", fromMe: true)])
    }

    /// One emoji per person: a new one replaces theirs, an empty one takes it back, and history brings them up to date.
    func testReactionsReplaceTakeBackAndRefresh() {
        let chat = "31600000001@s.whatsapp.net"
        let gowa = Data(#"""
        {"event":"message.reaction","payload":{"id":"X","chat_id":"31600000001@s.whatsapp.net","from":"31600000001@s.whatsapp.net","is_from_me":false,"reaction":"😂","reacted_message_id":"1"}}
        """#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: gowa),
                       .reaction(chat: chat, message: "1", emoji: "😂", sender: chat, fromMe: false))
        let openwa = Data(#"""
        {"event":"message.reaction","data":{"messageId":"1","chatId":"31600000001@c.us","reaction":"","senderId":"31600000001@c.us"}}
        """#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .openwa, body: openwa, me: "31699999999@s.whatsapp.net"),
                       .reaction(chat: "31600000001@c.us", message: "1", emoji: "", sender: "31600000001@c.us", fromMe: false))

        var inbox = WAInbox()
        inbox.add(message("1", chat: chat), filters: WAFilters())
        XCTAssertEqual(inbox.applyReaction("😂", message: "1", chat: chat, sender: chat, fromMe: false), chat)
        XCTAssertEqual(inbox.applyReaction("👍", message: "1", chat: chat, sender: "", fromMe: true), chat)
        // Their new emoji replaces their old one; yours stays.
        inbox.applyReaction("❤️", message: "1", chat: "31600000001@c.us", sender: "31600000001@c.us", fromMe: false)
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.reactions.map(\.emoji), ["👍", "❤️"])
        // An empty emoji takes yours back.
        inbox.applyReaction("", message: "1", chat: chat, sender: "", fromMe: true)
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.reactions.map(\.emoji), ["❤️"])
        XCTAssertNil(inbox.applyReaction("👍", message: "unknown", chat: chat, sender: chat, fromMe: false))

        // The same message from history again: still one message, with the reactions and the answer it carries now.
        var again = message("1", chat: chat)
        again.reactions = [WAReaction(emoji: "🙏", sender: chat)]
        again.replyTo = "0"
        XCTAssertEqual(inbox.add(again, filters: WAFilters(), history: true), .duplicate)
        XCTAssertEqual(inbox.conversations[chat]?.messages.count, 1)
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.reactions.map(\.emoji), ["🙏"])
        XCTAssertEqual(inbox.conversations[chat]?.messages.first?.replyTo, "0")
    }
}
