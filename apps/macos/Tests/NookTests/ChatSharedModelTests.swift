import XCTest

/// What every chat app's chats hold in the shared inbox since WhatsApp joined it: a chat known by its app's own id
/// (renames, two chats with one name, accounts), its kind, history that is never new, and the notice rules WhatsApp had
/// alone (`ChatNoticeRules`), the same for every app.
final class ChatSharedModelTests: XCTestCase {
    private func message(_ id: String, _ text: String = "hi", at seconds: TimeInterval = 0, mine: Bool = false,
                         sender: String = "", mentionsMe: Bool? = nil) -> InboxMessage {
        InboxMessage(id: id, sender: sender, text: text, date: Date(timeIntervalSince1970: 1_000 + seconds), fromMe: mine,
                     mentionsMe: mentionsMe)
    }

    private func chat(_ name: String, id: String? = nil, app: String = "whatsapp", _ messages: [InboxMessage],
                      kind: ChatKind? = nil, history: Bool = false) -> BridgedChat {
        BridgedChat(app: app, name: name, messages: messages, unread: nil, chatID: id, kind: kind, history: history)
    }

    // MARK: Known by its app's id

    func testAChatKnownByItsIdKeepsItsThreadWhenRenamed() {
        var inbox = ChatInbox()
        inbox.merge(chat("Family", id: "120363@g.us", [message("a")], kind: .group))
        inbox.merge(chat("Family 🏡", id: "120363@g.us", [message("b", at: 5)], kind: .group))
        XCTAssertEqual(inbox.threads.count, 1)
        let thread = inbox.threads[ChatInbox.key(app: "whatsapp", id: "120363@g.us")]
        XCTAssertEqual(thread?.name, "Family 🏡")
        XCTAssertEqual(thread?.messages.map(\.id), ["a", "b"])
        XCTAssertEqual(thread?.chatID, "120363@g.us")
    }

    func testARenameAloneIsSavedToo() {
        var inbox = ChatInbox()
        inbox.merge(chat("Anna", id: "316@s.whatsapp.net", [message("a")]))
        XCTAssertTrue(inbox.merge(chat("Anna B.", id: "316@s.whatsapp.net", [])), "the new name, without new messages")
        XCTAssertEqual(inbox.threads.values.first?.name, "Anna B.")
    }

    func testTwoChatsWithOneNameStayTwo() {
        var inbox = ChatInbox()
        inbox.merge(chat("Jan", id: "311@s.whatsapp.net", [message("a")]))
        inbox.merge(chat("Jan", id: "work~311@s.whatsapp.net", [message("b")]))
        XCTAssertEqual(inbox.threads.count, 2, "the same person in two accounts, or two people called Jan")
    }

    func testAnIdNeverMeetsANamesKey() {
        XCTAssertNotEqual(ChatInbox.key(app: "slack", id: "general"), ChatInbox.key(app: "slack", chat: "general"))
        XCTAssertNotEqual(ChatInbox.key(app: "slack", id: "x"), ChatInbox.key(app: "slack", chat: "#x"))
        XCTAssertEqual(ChatInbox.key(of: chat("Anna", app: "telegram", [])), ChatInbox.key(app: "telegram", chat: "Anna"),
                       "a bridge without ids keeps its chats where they were")
    }

    func testWhatTheAppSaysOfAChatIsKept() {
        var inbox = ChatInbox()
        var first = chat("Anna", id: "316@s.whatsapp.net", [message("a")], kind: .person)
        first.account = "Business"
        first.handle = "+316"
        first.readKnown = false
        first.hasOlder = true
        inbox.merge(first)
        var thread = inbox.threads.values.first
        XCTAssertEqual(thread?.account, "Business")
        XCTAssertEqual(thread?.kind, .person)
        XCTAssertEqual(thread?.handle, "+316")
        XCTAssertEqual(thread?.readKnown, false)
        XCTAssertEqual(thread?.hasOlder, true)
        var later = chat("Anna", id: "316@s.whatsapp.net", [])
        later.hasOlder = false
        XCTAssertTrue(inbox.merge(later), "reaching the chat's start is news without a new message")
        thread = inbox.threads.values.first
        XCTAssertEqual(thread?.hasOlder, false)
        XCTAssertEqual(thread?.account, "Business", "what a later read leaves out stays as it was")
    }

    func testTheAppsKindComesBeforeTheGuess() {
        var group = InboxThread(id: "x", app: "whatsapp", name: "Two of us")
        group.messages = [message("a")]
        XCTAssertFalse(group.isGroup)
        group.kind = .group
        XCTAssertTrue(group.isGroup)
        XCTAssertFalse(group.isPrivate)
        var channel = InboxThread(id: "y", app: "whatsapp", name: "News")
        channel.messages = [message("b", sender: "News")]
        channel.kind = .channel
        XCTAssertFalse(channel.isGroup, "a channel's posts name it, but it is no group")
        XCTAssertFalse(channel.isPrivate)
    }

    func testAChatKnownByItsIdIsNeverRegrouped() {
        var inbox = ChatInbox()
        inbox.merge(BridgedChat(app: "whatsapp", name: "Book club", messages: [message("g", sender: "Eva")], unread: nil,
                                members: ["Eva", "Tom"]))
        // A private chat the app knows by its id, with a message whose sender happens to be named like the group.
        inbox.merge(chat("Eva", id: "317@s.whatsapp.net", [message("p", sender: "Book club")], kind: .person))
        inbox.regroup()
        XCTAssertEqual(inbox.threads[ChatInbox.key(app: "whatsapp", id: "317@s.whatsapp.net")]?.messages.map(\.id), ["p"])
    }

    func testTheSameWordsTwiceInAChatKnownByItsIdAreTwoMessages() {
        var inbox = ChatInbox()
        inbox.merge(chat("Anna", id: "a", [message("1", "ok", at: 1), message("2", "ok", at: 2)]))
        XCTAssertEqual(inbox.threads.values.first?.messages.map(\.id), ["1", "2"], "every message by its own id")
        var named = ChatInbox()
        named.merge(chat("Anna", app: "slack", [message("1", "ok", at: 1), message("2", "ok", at: 2)]))
        XCTAssertEqual(named.threads.values.first?.messages.count, 1,
                       "a chat known by name keeps one copy of what a bridge and a notification both brought")
    }

    // MARK: History and mentions

    func testHistoryIsNeverNew() {
        var inbox = ChatInbox()
        inbox.merge(chat("Anna", id: "1", [message("a")]))
        inbox.merge(chat("Anna", id: "1", [message("b", at: 10)], history: true))
        XCTAssertEqual(inbox.threads.values.first?.unread, 0, "fetched as history: kept, not new")
        inbox.merge(chat("Anna", id: "1", [message("c", at: 20)]))
        XCTAssertEqual(inbox.threads.values.first?.unread, 1)
        XCTAssertEqual(inbox.threads.values.first?.messages.map(\.id), ["a", "b", "c"])
    }

    func testAMentionAddedLaterIsKept() {
        var inbox = ChatInbox()
        inbox.merge(chat("Group", id: "g", [message("a")], kind: .group))
        inbox.merge(chat("Group", id: "g", [message("a", mentionsMe: true)], kind: .group))
        XCTAssertEqual(inbox.threads.values.first?.messages.first?.mentionsMe, true)
    }

    // MARK: Notice rules, the same for every app

    func testWhatsAppKeepsItsKindsQuietAndOtherAppsKeepTellingAsBefore() {
        let rules = ChatNoticeRules()
        XCTAssertTrue(rules.isQuiet(chat: "c", app: "whatsapp", kind: .group))
        XCTAssertTrue(rules.isQuiet(chat: "c", app: "whatsapp", kind: .status))
        XCTAssertTrue(rules.isQuiet(chat: "c", app: "whatsapp", kind: .channel))
        XCTAssertFalse(rules.isQuiet(chat: "c", app: "whatsapp", kind: .person))
        XCTAssertFalse(rules.isQuiet(chat: "c", app: "whatsapp", kind: .group, mentionsMe: true), "a mention reaches you")
        for app in ["telegram", "slack", "teams", "messages", "signal"] {
            XCTAssertFalse(rules.isQuiet(chat: "c", app: app, kind: .group), app)
            XCTAssertFalse(rules.isQuiet(chat: "c", app: app, kind: nil), app)
        }
    }

    func testEveryAppCanKeepAKindQuiet() {
        var rules = ChatNoticeRules()
        rules.setQuiet(true, kind: .group, app: "telegram")
        XCTAssertTrue(rules.isQuiet(chat: "c", app: "telegram", kind: .group))
        XCTAssertFalse(rules.isQuiet(chat: "c", app: "telegram", kind: .group, mentionsMe: true))
        XCTAssertFalse(rules.isQuiet(chat: "c", app: "telegram", kind: .person))
        rules.setQuiet(false, kind: .group, app: "whatsapp")
        XCTAssertFalse(rules.isQuiet(chat: "c", app: "whatsapp", kind: .group))
        XCTAssertTrue(rules.isQuiet(chat: "c", app: "whatsapp", kind: .channel), "the other kinds keep their rule")
    }

    func testEachChatCanBeLouderOrQuieterThanItsKindInEveryApp() {
        var rules = ChatNoticeRules()
        rules.setMode(.loud, for: "whatsapp#1@g.us")
        rules.setMode(.muted, for: "telegram|anna")
        XCTAssertFalse(rules.isQuiet(chat: "whatsapp#1@g.us", app: "whatsapp", kind: .group))
        XCTAssertTrue(rules.isQuiet(chat: "telegram|anna", app: "telegram", kind: .person, mentionsMe: true),
                      "a muted chat never reaches you, a mention neither")
        rules.setMode(.automatic, for: "whatsapp#1@g.us")
        XCTAssertNil(rules.modes["whatsapp#1@g.us"], "automatic leaves the table")
        XCTAssertTrue(rules.isQuiet(chat: "whatsapp#1@g.us", app: "whatsapp", kind: .group))
    }

    func testAHiddenChatNeverReachesYouOrCounts() {
        var rules = ChatNoticeRules()
        rules.setHidden(true, chat: "slack|eva")
        rules.setMode(.loud, for: "slack|eva")
        XCTAssertTrue(rules.isQuiet(chat: "slack|eva", app: "slack", kind: .person), "hidden wins over loud")
        var thread = InboxThread(id: "slack|eva", app: "slack", name: "Eva")
        thread.messages = [message("a")]
        thread.unread = 1
        XCTAssertFalse(rules.isVisible(thread))
        rules.setHidden(false, chat: "slack|eva")
        XCTAssertTrue(rules.isVisible(thread))
    }

    func testTheBadgeLeavesQuietChatsOutUnlessTheyMentionedYou() {
        var inbox = ChatInbox()
        inbox.merge(chat("Anna", id: "p", [message("a")], kind: .person))
        inbox.merge(chat("Anna", id: "p", [message("b", at: 5)], kind: .person))
        inbox.merge(chat("Club", id: "g", [message("c")], kind: .group))
        inbox.merge(chat("Club", id: "g", [message("d", at: 5), message("e", at: 6)], kind: .group))
        inbox.merge(chat("Work", id: "w", [message("f")], kind: .group))
        inbox.merge(chat("Work", id: "w", [message("g", at: 5, mentionsMe: true)], kind: .group))
        let rules = ChatNoticeRules()
        XCTAssertEqual(inbox.totalUnread, 4)
        XCTAssertEqual(inbox.visibleUnread(rules), 2, "Anna's one, and Work's mention; Club stays quiet")
    }

    func testWhatsAppsOwnChoicesComeAlongForEveryAccount() {
        let ids: (String) -> [String] = { jid in ["whatsapp#" + jid, "whatsapp#work~" + jid] }
        let rules = ChatNoticeRules.migrated(muteGroups: false, muteStatus: true, muteChannels: false,
                                             ignored: ["31600000009@s.whatsapp.net"],
                                             modes: ["1@g.us": "loud", "31600000002@s.whatsapp.net": "muted", "x": "nonsense"],
                                             ids: ids)
        XCTAssertEqual(rules.quietKinds(for: "whatsapp"), [.status])
        XCTAssertEqual(rules.hidden, ["whatsapp#31600000009@s.whatsapp.net", "whatsapp#work~31600000009@s.whatsapp.net"])
        XCTAssertEqual(rules.mode(for: "whatsapp#1@g.us"), .loud)
        XCTAssertEqual(rules.mode(for: "whatsapp#work~1@g.us"), .loud)
        XCTAssertEqual(rules.mode(for: "whatsapp#31600000002@s.whatsapp.net"), .muted)
        XCTAssertEqual(rules.modes.count, 4, "an unknown choice is left out")
        XCTAssertEqual(rules.quietKinds(for: "telegram"), [], "other apps keep their own")
        XCTAssertTrue(rules.readsOnReply("whatsapp"))
        let off = ChatNoticeRules.migrated(muteGroups: true, muteStatus: true, muteChannels: true, ignored: [], modes: [:],
                                           readsOnReply: false, ids: ids)
        XCTAssertFalse(off.readsOnReply("whatsapp"), "WhatsApp's own choice comes along")
        XCTAssertTrue(off.readsOnReply("telegram"), "answering reads the chat in every app unless you choose otherwise")
    }

    func testRulesSavedBeforeAPartExistedStillLoad() throws {
        let old = #"{"modes":{"telegram|anna":"muted"},"hidden":["slack|eva"]}"#
        let rules = try JSONDecoder().decode(ChatNoticeRules.self, from: Data(old.utf8))
        XCTAssertEqual(rules.mode(for: "telegram|anna"), .muted)
        XCTAssertTrue(rules.isHidden("slack|eva"))
        XCTAssertTrue(rules.readsOnReply("slack"))
        XCTAssertEqual(rules.quietKinds(for: "whatsapp"), [.group, .status, .channel])
    }

    func testRulesSurviveARestart() throws {
        var rules = ChatNoticeRules()
        rules.setQuiet(true, kind: .channel, app: "telegram")
        rules.setMode(.loud, for: "whatsapp#1@g.us")
        rules.setHidden(true, chat: "slack|eva")
        let data = try JSONEncoder().encode(rules)
        XCTAssertEqual(try JSONDecoder().decode(ChatNoticeRules.self, from: data), rules)
    }

    func testAnInboxSavedBeforeStillLoads() throws {
        let old = #"{"threads":{"telegram|anna":{"id":"telegram|anna","app":"telegram","name":"Anna","messages":[{"id":"1","sender":"","text":"hi","date":0}],"unread":1}}}"#
        let inbox = try JSONDecoder().decode(ChatInbox.self, from: Data(old.utf8))
        let thread = inbox.threads["telegram|anna"]
        XCTAssertEqual(thread?.messages.first?.text, "hi")
        XCTAssertNil(thread?.chatID)
        XCTAssertNil(thread?.kind)
        XCTAssertNil(thread?.messages.first?.mentionsMe)
    }

    // MARK: Where a chat stands, as its app says

    func testWaitingInTheAppIsTheBridgesWord() {
        let newest = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ChatReadState.of(unread: 0, appUnread: 0, newestIncoming: newest, readInNook: nil, readInApp: nil,
                                        waitsInApp: true), .readInNook)
        XCTAssertEqual(ChatReadState.of(unread: 0, appUnread: 3, newestIncoming: newest, readInNook: newest, readInApp: nil,
                                        waitsInApp: false), .read, "read on the phone: read, whatever the count said")
        XCTAssertEqual(ChatReadState.of(unread: 0, appUnread: nil, newestIncoming: nil, readInNook: nil, readInApp: nil,
                                        waitsInApp: true), .readInNook, "also a chat Nook holds no messages of")
        XCTAssertEqual(ChatReadState.of(unread: 2, appUnread: nil, newestIncoming: newest, readInNook: nil, readInApp: nil,
                                        waitsInApp: false), .unread(2), "new in Nook comes first")
    }

    func testReadInNookHoldsAgainstTheAppsCount() {
        var inbox = ChatInbox()
        var first = chat("Anna", id: "a", [message("1")])
        first.unread = 2
        inbox.merge(first)
        let key = ChatInbox.key(app: "whatsapp", id: "a")
        XCTAssertEqual(inbox.threads[key]?.unread, 2)
        inbox.markRead(key, at: Date(timeIntervalSince1970: 2_000))
        var later = chat("Anna", id: "a", [])
        later.unread = 2
        later.waitsInApp = true
        inbox.merge(later)
        XCTAssertEqual(inbox.threads[key]?.unread, 0, "read in Nook stays read")
        XCTAssertEqual(inbox.threads[key]?.readState, .readInNook, "still unread on the phone")
        var reply = chat("Anna", id: "a", [message("2", at: 2_000)])
        reply.unread = 3
        reply.waitsInApp = true
        inbox.merge(reply)
        XCTAssertEqual(inbox.threads[key]?.unread, 1, "only what came after the read is new")
    }

    func testReadPassedOnToTheAppHoldsBeforeTheBridgesWord() {
        let newest = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ChatReadState.of(unread: 0, appUnread: 3, newestIncoming: newest, readInNook: newest, readInApp: newest,
                                        waitsInApp: true), .read, "the bridge has not read the app again yet")
        XCTAssertEqual(ChatReadState.of(unread: 0, appUnread: nil, newestIncoming: newest.addingTimeInterval(1),
                                        readInNook: newest, readInApp: newest, waitsInApp: true), .readInNook,
                       "a newer message waits in the app again")
    }

    func testMarkReadInAppSticksForEveryApp() {
        for app in ["whatsapp", "telegram", "slack", "instagram"] {
            var inbox = ChatInbox()
            var first = chat("Anna", id: "a", app: app, [message("1", at: 1_000)])
            first.unread = 1
            first.waitsInApp = true
            inbox.merge(first)
            let key = ChatInbox.key(app: app, id: "a")
            inbox.markReadInApp(key, at: Date(timeIntervalSince1970: 2_000))
            XCTAssertEqual(inbox.threads[key]?.readState, .read, app)
            // The bridge's next read still says the old word: read stays read.
            var stale = chat("Anna", id: "a", app: app, [message("1", at: 1_000)])
            stale.unread = 1
            stale.waitsInApp = true
            inbox.merge(stale)
            XCTAssertEqual(inbox.threads[key]?.readState, .read, app)
        }
    }

    func testReadHoldsAgainstAMessageDatedAhead() {
        var inbox = ChatInbox()
        // The phone says the chat last moved a minute ahead of this Mac's clock, by a message Nook holds not yet.
        let ahead = Date(timeIntervalSince1970: 2_060)
        var first = chat("Anna", id: "a", [message("1")])
        first.unread = 1
        first.activity = ahead
        inbox.merge(first)
        let key = ChatInbox.key(app: "whatsapp", id: "a")
        inbox.markRead(key, at: Date(timeIntervalSince1970: 2_000))
        inbox.forgetMessages(of: [key])
        var again = chat("Anna", id: "a", [])
        again.unread = 1
        again.activity = ahead
        inbox.merge(again)
        XCTAssertEqual(inbox.threads[key]?.unread, 0, "what was read is not new again")
    }

    func testMarkedUnreadHoldsAgainstALaggingCount() {
        for app in ["slack", "teams", "messages", "whatsapp"] {
            var inbox = ChatInbox()
            var first = chat("Anna", id: "a", app: app, [message("1")])
            first.unread = 1
            inbox.merge(first)
            let key = ChatInbox.key(app: app, id: "a")
            inbox.markReadInApp(key, at: Date(timeIntervalSince1970: 2_000))
            // The app's next read still counts the old message, then catches up.
            var lagging = chat("Anna", id: "a", app: app, [message("1")])
            lagging.unread = 1
            inbox.merge(lagging)
            inbox.markUnread(key, at: Date(timeIntervalSince1970: 2_100))
            var caughtUp = chat("Anna", id: "a", app: app, [message("1")])
            caughtUp.unread = 0
            inbox.merge(caughtUp)
            XCTAssertEqual(inbox.threads[key]?.readState, .unread(1), "\(app): marked unread stays unread")
            inbox.markRead(key, at: Date(timeIntervalSince1970: 2_200))
            XCTAssertNil(inbox.threads[key]?.markedUnread, app)
            XCTAssertEqual(inbox.threads[key]?.unread, 0, app)
        }
    }

    func testAnsweringEndsAMarkedUnread() {
        var inbox = ChatInbox()
        var first = chat("Anna", id: "a", app: "slack", [message("1")])
        first.unread = 0
        inbox.merge(first)
        let key = ChatInbox.key(app: "slack", id: "a")
        inbox.markUnread(key, at: Date(timeIntervalSince1970: 1_100))
        // You answer in Slack itself.
        var answered = chat("Anna", id: "a", app: "slack", [message("1"), message("2", at: 200, mine: true)])
        answered.unread = 0
        inbox.merge(answered)
        XCTAssertNil(inbox.threads[key]?.markedUnread)
        XCTAssertEqual(inbox.threads[key]?.unread, 0)
    }

    func testReadInTheAppKeepsWhatCameInMeanwhile() {
        var inbox = ChatInbox()
        var first = chat("Anna", id: "a", app: "telegram", [message("1")])
        first.unread = 1
        inbox.merge(first)
        let key = ChatInbox.key(app: "telegram", id: "a")
        inbox.markRead(key, at: Date(timeIntervalSince1970: 1_500))
        let through = inbox.threads[key]?.readInNook
        // A message comes in while the app is being told.
        var meanwhile = chat("Anna", id: "a", app: "telegram", [message("1"), message("2", at: 900)])
        meanwhile.unread = 1
        inbox.merge(meanwhile)
        inbox.markReadInApp(key, at: Date(timeIntervalSince1970: 2_000), through: through)
        XCTAssertEqual(inbox.threads[key]?.unread, 1, "the message that came in meanwhile stays new")
        XCTAssertEqual(inbox.threads[key]?.readState, .unread(1))
    }

    func testTwinsAreTheThreadsWithTheSameNewestMessage() {
        var inbox = ChatInbox()
        inbox.merge(chat("Jan", app: "teams", [message("x")]))
        inbox.merge(chat("Piet", app: "teams", [message("x")]))
        inbox.merge(chat("Kees", app: "teams", [message("y")]))
        let jan = ChatInbox.key(app: "teams", chat: "Jan")
        XCTAssertEqual(inbox.twins(of: jan), [ChatInbox.key(app: "teams", chat: "Piet")])
    }

    func testAChatWithoutMessagesGoesByWhenItLastHadOne() {
        var inbox = ChatInbox()
        var listed = chat("Bob", id: "b", [])
        listed.listed = true
        listed.unread = 4
        listed.activity = Date(timeIntervalSince1970: 500)
        inbox.merge(listed)
        let key = ChatInbox.key(app: "whatsapp", id: "b")
        XCTAssertEqual(inbox.threads[key]?.unread, 4)
        XCTAssertEqual(inbox.threads[key]?.last, Date(timeIntervalSince1970: 500), "it sorts where it last had a message")
        inbox.markRead(key, at: Date(timeIntervalSince1970: 600))
        inbox.merge(listed)
        XCTAssertEqual(inbox.threads[key]?.unread, 0, "read in Nook after its last message")
        listed.activity = Date(timeIntervalSince1970: 700)
        listed.unread = 5
        inbox.merge(listed)
        XCTAssertEqual(inbox.threads[key]?.unread, 5, "a message after the read: the app's count again")
    }

    // MARK: Never on disk

    func testAChatWhoseAppKeepsItsMessagesIsWrittenWithoutThem() throws {
        var inbox = ChatInbox()
        var whatsApp = chat("Anna", id: "a", [message("secret", "private words", at: 10)])
        whatsApp.ephemeral = true
        inbox.merge(whatsApp)
        inbox.merge(chat("Anna", app: "telegram", [message("t", "kept", at: 10)]))
        let key = ChatInbox.key(app: "whatsapp", id: "a")
        inbox.markRead(key)
        let data = try JSONEncoder().encode(inbox.forDisk)
        let written = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(written.contains("private words"))
        XCTAssertFalse(written.contains("secret"))
        XCTAssertTrue(written.contains("kept"), "other apps' chats are kept as they always were")
        let loaded = try JSONDecoder().decode(ChatInbox.self, from: data)
        XCTAssertEqual(loaded.threads[key]?.messages, [])
        XCTAssertNotNil(loaded.threads[key]?.readInNook, "what Nook knows of the chat stays")
        XCTAssertEqual(loaded.threads[key]?.last, Date(timeIntervalSince1970: 1_010), "and where it sorts")
        XCTAssertEqual(inbox.threads[key]?.messages.count, 1, "in memory the chat keeps its messages")
    }

    func testTurningAnAppOffLetsGoOfItsMessagesInMemory() {
        var inbox = ChatInbox()
        inbox.merge(chat("Anna", id: "a", [message("1", at: 10)]))
        let key = ChatInbox.key(app: "whatsapp", id: "a")
        inbox.forgetMessages(of: [key])
        XCTAssertEqual(inbox.threads[key]?.messages, [])
        XCTAssertEqual(inbox.threads[key]?.last, Date(timeIntervalSince1970: 1_010))
    }

    func testIdsFromBeforeTheSharedInboxStillFindTheirChat() {
        XCTAssertEqual(ChatIDMigration.current("wa|31612345678@s.whatsapp.net"), ChatInbox.key(app: "whatsapp", id: "31612345678@s.whatsapp.net"))
        XCTAssertEqual(ChatIDMigration.current("wa|work~1@g.us"), "whatsapp#work~1@g.us")
        XCTAssertEqual(ChatIDMigration.current("telegram|anna"), "telegram|anna")
        XCTAssertEqual(ChatIDMigration.current("whatsapp#1@g.us"), "whatsapp#1@g.us")
        XCTAssertEqual(ChatIDMigration.previous("whatsapp#work~1@g.us"), "wa|work~1@g.us")
        XCTAssertNil(ChatIDMigration.previous("telegram|anna"))
        let kept = ChatIDMigration.current(["wa|1@g.us": Set(["a"]), "whatsapp#1@g.us": Set(["b"]), "slack|eva": Set(["c"])]) {
            $0.union($1)
        }
        XCTAssertEqual(kept, ["whatsapp#1@g.us": ["a", "b"], "slack|eva": ["c"]], "what was kept under both ids is joined")
    }

    func testEveryAppsGroupsCountAsGroupsForTheRules() {
        var group = InboxThread(id: "telegram|club", app: "telegram", name: "Club")
        group.members = ["Eva", "Tom"]
        XCTAssertEqual(group.noticeKind, .group, "the app does not say: its people do")
        var person = InboxThread(id: "telegram|anna", app: "telegram", name: "Anna")
        person.messages = [message("1")]
        XCTAssertEqual(person.noticeKind, .person)
        var channel = InboxThread(id: "whatsapp#x@newsletter", app: "whatsapp", name: "News")
        channel.kind = .channel
        XCTAssertEqual(channel.noticeKind, .channel, "what the app says comes first")
        var rules = ChatNoticeRules()
        rules.setQuiet(true, kind: .group, app: "telegram")
        group.messages = [message("2", sender: "Eva")]
        group.unread = 1
        XCTAssertFalse(rules.isVisible(group), "Telegram's groups can stay quiet too")
        XCTAssertEqual(ChatNoticeRules.kinds(of: "whatsapp"), [.group, .status, .channel])
        XCTAssertEqual(ChatNoticeRules.kinds(of: "telegram"), [.group])
    }
}
