import XCTest

/// Every chat in one place: which notifications are chat messages, which chat they belong to, and how a chat reads as
/// bubbles.
final class ChatInboxTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func notification(_ bundle: String, title: String, subtitle: String = "", body: String,
                              record: Int64 = 1) -> CapturedNotification {
        CapturedNotification(record: record, bundleID: bundle, title: title, subtitle: subtitle, body: body, date: now)
    }

    // MARK: Which app

    func testMacAppsByTheirBundle() {
        XCTAssertEqual(MessagingApps.app(bundleID: "ru.keepcoder.Telegram")?.id, "telegram")
        XCTAssertEqual(MessagingApps.app(bundleID: "ORG.telegram.desktop")?.id, "telegram")
        XCTAssertEqual(MessagingApps.app(bundleID: "com.facebook.archon")?.id, "messenger")
        XCTAssertEqual(MessagingApps.app(bundleID: "org.whispersystems.signal-desktop")?.id, "signal")
        XCTAssertEqual(MessagingApps.app(bundleID: "com.apple.MobileSMS")?.id, "messages")
        XCTAssertNil(MessagingApps.app(bundleID: "com.apple.mail"))
    }

    func testBrowsersNameTheSite() {
        XCTAssertTrue(MessagingApps.isBrowser("com.google.Chrome"))
        XCTAssertTrue(MessagingApps.isBrowser("com.apple.Safari.WebApp.1234"))
        XCTAssertTrue(MessagingApps.isBrowser("company.thebrowser.Browser"))
        XCTAssertFalse(MessagingApps.isBrowser("ru.keepcoder.Telegram"))
        XCTAssertEqual(MessagingApps.app(mentionedIn: ["www.instagram.com", "anna", "hoi"])?.id, "instagram")
        XCTAssertEqual(MessagingApps.app(mentionedIn: ["", "Instagram", "anna: hoi"])?.id, "instagram")
        XCTAssertNil(MessagingApps.app(mentionedIn: ["notinstagram.com", "News", "read this"]))
        XCTAssertNil(MessagingApps.app(mentionedIn: ["github.com", "Build failed", ""]))
    }

    func testLinkedInAndXFromTheBrowser() {
        let notice = ChatCapture.notice(notification("com.google.Chrome", title: "Jan de Vries", subtitle: "www.linkedin.com",
                                                     body: "Thanks for connecting!"))
        XCTAssertEqual(notice, ChatNotice(app: "linkedin", chat: "Jan de Vries", sender: "", text: "Thanks for connecting!", date: now))
        XCTAssertEqual(MessagingApps.app(mentionedIn: ["x.com", "Anna", "hi"])?.id, "x")
        XCTAssertNil(MessagingApps.app(mentionedIn: ["box.com", "Anna", "hi"]), "x.com is no part of box.com")
    }

    // MARK: Sources

    func testASwitchedOffAppIsNotCollected() {
        var sources = ChatSources()
        sources.set("telegram", on: false)
        let telegram = notification("ru.keepcoder.Telegram", title: "Anna", body: "Hi")
        XCTAssertNil(ChatCapture.notice(telegram, apps: sources.active))
        sources.set("telegram", on: true)
        XCTAssertEqual(ChatCapture.notice(telegram, apps: sources.active)?.app, "telegram")
    }

    func testAddingAWebsite() {
        var sources = ChatSources()
        guard case .added(let app) = sources.add("https://www.example-chat.io/inbox?x=1") else { return XCTFail("not added") }
        XCTAssertEqual(app.id, "custom.example-chat.io")
        XCTAssertEqual(app.name, "Example-chat")
        XCTAssertEqual(app.domains, ["example-chat.io"])
        XCTAssertTrue(sources.isOn(app.id))
        let notice = ChatCapture.notice(notification("com.apple.Safari", title: "Bo", subtitle: "example-chat.io", body: "Hey"),
                                        apps: sources.active)
        XCTAssertEqual(notice?.app, app.id)
        XCTAssertEqual(notice?.chat, "Bo")
        XCTAssertEqual(sources.add("example-chat.io/other"), .known(app), "no second copy")
        sources.remove(app.id)
        XCTAssertTrue(sources.custom.isEmpty)
    }

    func testAddingAKnownAppSwitchesItOn() {
        var sources = ChatSources()
        sources.set("linkedin", on: false)
        XCTAssertEqual(sources.add("linkedin.com/messaging"), .known(MessagingApps.app(named: "LinkedIn")!))
        XCTAssertTrue(sources.isOn("linkedin"))
        sources.set("telegram", on: false)
        XCTAssertEqual(sources.add("Telegram").isKnown, true)
        XCTAssertTrue(sources.isOn("telegram"))
        XCTAssertEqual(sources.add("web.telegram.org").isKnown, true)
        XCTAssertTrue(sources.custom.isEmpty)
    }

    func testAddingSomethingThatIsNoSource() {
        var sources = ChatSources()
        XCTAssertEqual(sources.add("my friends"), .invalid)
        XCTAssertEqual(sources.add("localhost"), .invalid)
        XCTAssertEqual(sources.add("a..b"), .invalid)
        XCTAssertEqual(sources.add(bundleID: "com.google.Chrome", name: "Chrome"), .invalid, "a browser is no chat app")
        XCTAssertTrue(sources.custom.isEmpty)
    }

    func testAddingAMacApp() {
        var sources = ChatSources()
        guard case .added(let app) = sources.add(bundleID: "com.example.Chatter", name: "Chatter") else { return XCTFail("not added") }
        XCTAssertEqual(app.bundleIDs, ["com.example.Chatter"])
        XCTAssertEqual(ChatCapture.notice(notification("com.example.Chatter", title: "Kim", body: "Yo"), apps: sources.active)?.app, app.id)
        XCTAssertEqual(sources.add(bundleID: "ru.keepcoder.Telegram", name: "Telegram").isKnown, true)
    }

    func testHostOfWhatWasTyped() {
        XCTAssertEqual(ChatSources.host("LinkedIn.com/messaging/"), "linkedin.com")
        XCTAssertEqual(ChatSources.host("https://www.x.com"), "x.com")
        XCTAssertNil(ChatSources.host("linkedin"))
        XCTAssertNil(ChatSources.host("site.c0m"))
        XCTAssertEqual(ChatSources.title(for: "app.example.org"), "Example")
    }

    func testSourcesSurviveAnEncode() throws {
        var sources = ChatSources()
        sources.set("signal", on: false)
        _ = sources.add("example-chat.io")
        let data = try JSONEncoder().encode(sources)
        XCTAssertEqual(try JSONDecoder().decode(ChatSources.self, from: data), sources)
    }

    // MARK: Nook writes a message

    func testMenuUnderTheAt() {
        let presets = ["Say yes", "Say no, kindly", "Thank them"]
        let at = ChatDraft.choices(for: "@", presets: presets)
        XCTAssertEqual(at.first, ChatDraft.Choice(insertion: "@nook ", title: "@nook", isNook: true))
        XCTAssertEqual(at.dropFirst().map(\.insertion), ["@nook Say yes", "@nook Say no, kindly", "@nook Thank them"])
        XCTAssertEqual(ChatDraft.choices(for: "@NO", presets: presets).count, 4, "any case, on the way to @nook")
        XCTAssertEqual(ChatDraft.choices(for: "@nook ", presets: presets).map(\.title),
                       ["@nook Say yes", "@nook Say no, kindly", "@nook Thank them"], "@nook typed in full: only the requests")
        XCTAssertEqual(ChatDraft.choices(for: "@nook say", presets: presets).map(\.insertion), ["@nook Say yes", "@nook Say no, kindly"])
        XCTAssertEqual(ChatDraft.choices(for: "@nook Say yes", presets: presets), [], "typed in full: Return lets Nook write")
        XCTAssertEqual(ChatDraft.choices(for: "@nook tell him I'm late", presets: presets), [])
        XCTAssertEqual(ChatDraft.choices(for: "@lisa", presets: presets), [])
        XCTAssertEqual(ChatDraft.choices(for: "hi @", presets: presets), [], "only at the start")
        XCTAssertEqual(ChatDraft.choices(for: "", presets: presets), [])
    }

    func testSteeringADraft() {
        let request = ChatDraft.refinement(of: "  Sure, see you at 8!\n", change: " Make it shorter. ")
        XCTAssertTrue(request.contains("<<<\nSure, see you at 8!\n>>>"), "the draft as it is in the field, trimmed")
        XCTAssertTrue(request.hasSuffix("The change: Make it shorter."))
        XCTAssertTrue(ChatDraft.refinement(of: "Hi", change: "  ").hasSuffix("The change: " + ChatDraft.Tweak.again.request),
                      "no change typed: other words")
        XCTAssertEqual(Set(ChatDraft.Tweak.allCases.map(\.titleKey)).count, ChatDraft.Tweak.allCases.count)
    }

    func testNookInstruction() {
        XCTAssertEqual(ChatDraft.instruction(in: "@nook say yes, short"), "say yes, short")
        XCTAssertEqual(ChatDraft.instruction(in: "  @Nook: zeg dat ik later ben"), "zeg dat ik later ben")
        XCTAssertEqual(ChatDraft.instruction(in: "@nook"), "")
        XCTAssertNil(ChatDraft.instruction(in: "@nookie"))
        XCTAssertNil(ChatDraft.instruction(in: "see you @nook"))
    }

    func testDraftPromptAndCleanAnswer() {
        let prompt = ChatDraft.prompt(app: "Telegram", chat: "Anna", transcript: "[12:04] Anna: Dinner?", instruction: "")
        XCTAssertTrue(prompt.contains("Telegram chat with Anna"))
        XCTAssertTrue(prompt.contains("[12:04] Anna: Dinner?"))
        XCTAssertTrue(prompt.contains("fitting answer"))
        XCTAssertEqual(ChatDraft.clean("\"Sure, see you at 8!\""), "Sure, see you at 8!")
        XCTAssertEqual(ChatDraft.clean("Message: Sounds good"), "Sounds good")
        XCTAssertEqual(ChatDraft.clean("He said \"hi\" and \"bye\""), "He said \"hi\" and \"bye\"")
        XCTAssertNil(ChatDraft.clean("  \"\" "))
    }

    // MARK: What a notification says

    func testPrivateChat() {
        let notice = ChatCapture.notice(notification("ru.keepcoder.Telegram", title: "Anna", body: "See you at eight"))
        XCTAssertEqual(notice, ChatNotice(app: "telegram", chat: "Anna", sender: "", text: "See you at eight", date: now))
    }

    func testGroupWithTheSenderAsSubtitle() {
        let notice = ChatCapture.notice(notification("ru.keepcoder.Telegram", title: "Family", subtitle: "Jan", body: "Dinner?"))
        XCTAssertEqual(notice?.chat, "Family")
        XCTAssertEqual(notice?.sender, "Jan")
    }

    func testWhatsAppGroupAsNameAtGroup() {
        let notice = ChatCapture.notice(notification("net.whatsapp.WhatsApp", title: "Jan @ Family", body: "Dinner?"))
        XCTAssertEqual(notice?.chat, "Family")
        XCTAssertEqual(notice?.sender, "Jan")
    }

    func testWebNotificationTitledWithTheApp() {
        let notice = ChatCapture.notice(notification("com.google.Chrome", title: "Instagram", subtitle: "www.instagram.com",
                                                     body: "anna.b: did you see this?"))
        XCTAssertEqual(notice, ChatNotice(app: "instagram", chat: "anna.b", sender: "", text: "did you see this?", date: now))
    }

    func testWebNotificationFromTheSite() {
        let notice = ChatCapture.notice(notification("com.google.Chrome", title: "Mark", subtitle: "www.messenger.com", body: "Hey"))
        XCTAssertEqual(notice?.app, "messenger")
        XCTAssertEqual(notice?.chat, "Mark")
        XCTAssertEqual(notice?.sender, "", "the site is no sender")
    }

    func testNotChats() {
        XCTAssertNil(ChatCapture.notice(notification("com.apple.mail", title: "Anna", body: "Invoice")))
        XCTAssertNil(ChatCapture.notice(notification("com.google.Chrome", title: "Build failed", subtitle: "github.com", body: "main")))
        XCTAssertNil(ChatCapture.notice(notification("ru.keepcoder.Telegram", title: "Anna", body: "")), "nothing said")
        XCTAssertNil(ChatCapture.notice(notification("com.google.Chrome", title: "Instagram", subtitle: "instagram.com",
                                                     body: "New login from Chrome")), "no one wrote this")
    }

    func testSpeaker() {
        XCTAssertEqual(ChatCapture.speaker("anna: hi")?.0, "anna")
        XCTAssertEqual(ChatCapture.speaker("anna: hi")?.1, "hi")
        XCTAssertNil(ChatCapture.speaker("see https://example.com"))
        XCTAssertNil(ChatCapture.speaker("no colon here"))
        XCTAssertNil(ChatCapture.speaker(String(repeating: "a", count: 41) + ": x"))
    }

    // MARK: Notification Center's database

    func testRecordFromItsPropertyList() throws {
        let plist: [String: Any] = ["app": "ru.keepcoder.Telegram", "date": 800_000_123.0,
                                    "req": ["titl": " Anna ", "subt": "", "body": "Hoi"]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let hex = data.map { String(format: "%02X", $0) }.joined()
        let notification = NotificationRecord.notification(["id": 42, "app": "ru.keepcoder.Telegram", "date": 1.0, "data": hex])
        XCTAssertEqual(notification?.record, 42)
        XCTAssertEqual(notification?.title, "Anna")
        XCTAssertEqual(notification?.body, "Hoi")
        XCTAssertEqual(notification?.date, Date(timeIntervalSinceReferenceDate: 800_000_123))
    }

    func testUnreadableRecords() {
        XCTAssertNil(NotificationRecord.notification(["id": 1, "app": "x", "data": "ZZ"]))
        XCTAssertNil(NotificationRecord.notification(["id": 1, "app": "x", "data": "ABC"]))
        XCTAssertNil(NotificationRecord.notification(["app": "x", "data": "00"]))
        XCTAssertEqual(NotificationRecord.data(hex: "00FF7f"), Data([0, 255, 127]))
    }

    func testQueryContinuesAfterTheLastRecord() {
        XCTAssertTrue(NotificationRecord.query(after: 17, since: now).contains("r.rec_id > 17"))
        XCTAssertTrue(NotificationRecord.query(after: nil, since: now).contains("r.delivered_date > 800000000"))
    }

    // MARK: The inbox

    private func notice(_ chat: String, _ text: String, app: String = "telegram", sender: String = "",
                        at offset: TimeInterval = 0) -> ChatNotice {
        ChatNotice(app: app, chat: chat, sender: sender, text: text, date: now.addingTimeInterval(offset))
    }

    func testMessagesGoToTheirChat() {
        var inbox = ChatInbox()
        XCTAssertTrue(inbox.add(notice("Anna", "one"), id: "1"))
        XCTAssertTrue(inbox.add(notice("anna", "two", at: 10), id: "2"), "the same chat, written differently")
        XCTAssertTrue(inbox.add(notice("Anna", "three", app: "signal", at: 20), id: "3"), "another app is another chat")
        XCTAssertEqual(inbox.threads.count, 2)
        let telegram = inbox.threads[ChatInbox.key(app: "telegram", chat: "Anna")]
        XCTAssertEqual(telegram?.messages.map(\.text), ["one", "two"])
        XCTAssertEqual(telegram?.unread, 2)
        XCTAssertEqual(inbox.sorted.first?.app, "signal", "newest first")
        XCTAssertEqual(inbox.totalUnread, 3)
    }

    func testFreshChatsAreTheOnesSomeoneJustWroteIn() {
        var before = ChatInbox()
        before.add(notice("Anna", "old", at: -3600), id: "1")
        before.add(notice("Ben", "seen", at: 0), id: "2")
        var after = before
        after.add(notice("Anna", "new", at: 20), id: "3")
        after.add(notice("Cas", "hello", at: 10), id: "4")
        after.add(notice("Dirk", "long ago", at: -7200), id: "5")
        let since = now.addingTimeInterval(-600)
        XCTAssertEqual(ChatInbox.fresh(before: before, after: after, since: since),
                       [ChatInbox.key(app: "telegram", chat: "Cas"), ChatInbox.key(app: "telegram", chat: "Anna")],
                       "oldest first; Ben had nothing new and Dirk's message is too old to be news")
        XCTAssertEqual(ChatInbox.fresh(before: after, after: after, since: since), [])
    }

    func testTheSameNotificationTwiceIsOneMessage() {
        var inbox = ChatInbox()
        XCTAssertTrue(inbox.add(notice("Anna", "hi"), id: "1"))
        XCTAssertFalse(inbox.add(notice("Anna", "hi", at: 5), id: "2"))
        XCTAssertFalse(inbox.add(notice("Anna", "other", at: 6), id: "1"))
        XCTAssertTrue(inbox.add(notice("Anna", "hi", at: 300), id: "3"), "said again later")
        XCTAssertEqual(inbox.threads.first?.value.messages.count, 2)
    }

    func testALateNotificationGoesInItsPlace() {
        var inbox = ChatInbox()
        inbox.add(notice("Anna", "second", at: 10), id: "2")
        inbox.add(notice("Anna", "first", at: 0), id: "1")
        XCTAssertEqual(inbox.threads.first?.value.messages.map(\.text), ["first", "second"])
    }

    func testKeepsTheNewestMessages() {
        var inbox = ChatInbox()
        for index in 0..<(ChatInbox.keep + 5) { inbox.add(notice("Anna", "m\(index)", at: Double(index)), id: "\(index)") }
        let messages = inbox.threads.first!.value.messages
        XCTAssertEqual(messages.count, ChatInbox.keep)
        XCTAssertEqual(messages.last?.text, "m\(ChatInbox.keep + 4)")
    }

    func testReadAndRemove() {
        var inbox = ChatInbox()
        inbox.add(notice("Anna", "hi"), id: "1")
        inbox.add(notice("Jan", "yo"), id: "2")
        let anna = ChatInbox.key(app: "telegram", chat: "Anna")
        inbox.markRead(anna)
        XCTAssertEqual(inbox.threads[anna]?.unread, 0)
        XCTAssertEqual(inbox.totalUnread, 1)
        inbox.markAllRead()
        XCTAssertEqual(inbox.totalUnread, 0)
        inbox.remove(anna)
        XCTAssertNil(inbox.threads[anna])
    }

    func testOldChatsAreDropped() {
        var inbox = ChatInbox()
        inbox.add(notice("Anna", "hi"), id: "1")
        inbox.trim(now: now.addingTimeInterval(ChatInbox.maxAge + 1))
        XCTAssertTrue(inbox.threads.isEmpty)
    }

    func testGroupsAndApps() {
        var inbox = ChatInbox()
        inbox.add(notice("Family", "dinner?", sender: "Jan"), id: "1")
        inbox.add(notice("Anna", "hi", app: "signal"), id: "2")
        inbox.add(notice("Jan", "yo", app: "signal"), id: "3")
        XCTAssertTrue(inbox.threads[ChatInbox.key(app: "telegram", chat: "Family")]!.isGroup)
        XCTAssertFalse(inbox.threads[ChatInbox.key(app: "signal", chat: "Anna")]!.isGroup)
        XCTAssertEqual(inbox.apps, ["signal", "telegram"])
    }

    func testSurvivesARelaunch() throws {
        var inbox = ChatInbox()
        inbox.add(notice("Anna", "hi"), id: "1")
        inbox.lastRecord = 9
        let decoded = try JSONDecoder().decode(ChatInbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertEqual(decoded, inbox)
    }

    func testAnInboxFromBeforeBridgesStillLoads() throws {
        let json = #"{"threads":{"telegram|anna":{"id":"telegram|anna","app":"telegram","name":"Anna","unread":1,"#
            + #""messages":[{"id":"1","sender":"","text":"hi","date":800000000}]}},"lastRecord":3}"#
        let inbox = try JSONDecoder().decode(ChatInbox.self, from: Data(json.utf8))
        XCTAssertEqual(inbox.threads["telegram|anna"]?.messages.first?.isMine, false)
        XCTAssertNil(inbox.removed)
    }

    // MARK: Bridges

    private func message(_ id: String, _ text: String, at offset: TimeInterval = 0, mine: Bool = false,
                         sender: String = "") -> InboxMessage {
        InboxMessage(id: id, sender: sender, text: text, date: now.addingTimeInterval(offset), fromMe: mine)
    }

    func testABridgeBringsHistoryAsRead() {
        var inbox = ChatInbox()
        XCTAssertTrue(inbox.merge(BridgedChat(app: "slack", name: "Anna",
                                              messages: [message("a", "hi"), message("b", "hey", at: 10, mine: true)], unread: nil)))
        let thread = inbox.threads[ChatInbox.key(app: "slack", chat: "Anna")]
        XCTAssertEqual(thread?.messages.map(\.text), ["hi", "hey"])
        XCTAssertEqual(thread?.unread, 0, "the history on the first look was read in the app already")
        XCTAssertEqual(thread?.messages.last?.isMine, true)
        XCTAssertFalse(thread?.isGroup ?? true, "your own messages carry no sender")
    }

    func testNewMessagesFromOthersCountAsUnread() {
        var inbox = ChatInbox()
        inbox.merge(BridgedChat(app: "slack", name: "Anna", messages: [message("a", "hi")], unread: nil))
        inbox.merge(BridgedChat(app: "slack", name: "Anna",
                                messages: [message("a", "hi"), message("b", "mine", at: 5, mine: true), message("c", "new", at: 10)],
                                unread: nil))
        XCTAssertEqual(inbox.threads[ChatInbox.key(app: "slack", chat: "Anna")]?.unread, 1)
        XCTAssertFalse(inbox.merge(BridgedChat(app: "slack", name: "Anna", messages: [message("c", "new", at: 10)], unread: nil)),
                       "nothing new")
    }

    func testABridgeAndANotificationAreOneMessage() {
        var inbox = ChatInbox()
        inbox.add(notice("Anna", "hi", app: "messages"), id: "n1")
        inbox.merge(BridgedChat(app: "messages", name: "Anna", messages: [message("imessage-9", "hi", at: 2)], unread: 1))
        XCTAssertEqual(inbox.threads[ChatInbox.key(app: "messages", chat: "Anna")]?.messages.count, 1)
        XCTAssertFalse(inbox.add(notice("Anna", "hi", app: "messages", at: 3), id: "n2"))
        // The same words from you are another message.
        inbox.merge(BridgedChat(app: "messages", name: "Anna", messages: [message("imessage-10", "hi", at: 4, mine: true)], unread: 1))
        XCTAssertEqual(inbox.threads[ChatInbox.key(app: "messages", chat: "Anna")]?.messages.count, 2)
    }

    func testTheAppsUnreadCountWinsOnlyWhenItChanges() {
        var inbox = ChatInbox()
        let key = ChatInbox.key(app: "messages", chat: "Anna")
        inbox.merge(BridgedChat(app: "messages", name: "Anna", messages: [message("1", "hi")], unread: 2))
        XCTAssertEqual(inbox.threads[key]?.unread, 2)
        inbox.markRead(key)
        inbox.merge(BridgedChat(app: "messages", name: "Anna", messages: [], unread: 2))
        XCTAssertEqual(inbox.threads[key]?.unread, 0, "read in Nook stays read")
        inbox.merge(BridgedChat(app: "messages", name: "Anna", messages: [message("2", "again", at: 5)], unread: 3))
        XCTAssertEqual(inbox.threads[key]?.unread, 3)
        XCTAssertFalse(inbox.merge(BridgedChat(app: "messages", name: "Jan", messages: [], unread: 4)),
                       "a count alone does not make a chat")
    }

    func testARemovedChatComesBackOnlyWithNewMessages() {
        var inbox = ChatInbox()
        let key = ChatInbox.key(app: "slack", chat: "Anna")
        inbox.merge(BridgedChat(app: "slack", name: "Anna", messages: [message("a", "hi")], unread: nil))
        inbox.remove(key, at: now.addingTimeInterval(5))
        XCTAssertFalse(inbox.merge(BridgedChat(app: "slack", name: "Anna", messages: [message("a", "hi")], unread: nil)))
        XCTAssertTrue(inbox.merge(BridgedChat(app: "slack", name: "Anna", messages: [message("b", "later", at: 10)], unread: nil)))
        XCTAssertEqual(inbox.threads[key]?.messages.map(\.text), ["later"])
    }

    func testARemovedChatDoesNotComeBackFromOldNotifications() {
        var inbox = ChatInbox()
        let key = ChatInbox.key(app: "telegram", chat: "Anna")
        inbox.add(notice("Anna", "hi"), id: "n1")
        inbox.remove(key, at: now.addingTimeInterval(5))
        // Looking back again reads the same notification once more.
        XCTAssertFalse(inbox.add(notice("Anna", "hi"), id: "n1"))
        XCTAssertNil(inbox.threads[key])
        XCTAssertTrue(inbox.add(notice("Anna", "later", at: 10), id: "n2"))
        XCTAssertEqual(inbox.threads[key]?.messages.map(\.text), ["later"])
    }

    func testSlackAndTeamsNotificationsFromTheirMacApps() {
        let slack = ChatCapture.notice(notification("com.tinyspeck.slackmacgap", title: "New message in #github-updates",
                                                    body: "GitHub: [acme/app] Workflow triggered by <https://github.com/ada|ada>"))
        XCTAssertEqual(slack?.app, "slack")
        XCTAssertEqual(slack?.chat, "#github-updates", "the channel, not Slack's sentence around it")
        XCTAssertEqual(slack?.sender, "GitHub")
        XCTAssertEqual(slack?.text, "[acme/app] Workflow triggered by ada", "Slack's link markup as its label")
        let direct = ChatCapture.notice(notification("com.tinyspeck.slackmacgap", title: "New message from Anna", body: "Note: lunch?"))
        XCTAssertEqual(direct?.chat, "Anna")
        XCTAssertEqual(direct?.sender, "", "a direct message has no sender of its own")
        XCTAssertEqual(direct?.text, "Note: lunch?")
        let teams = ChatCapture.notice(notification("com.microsoft.teams2", title: "Mindlinq Business & Dev",
                                                    body: "Aron: Ter info"))
        XCTAssertEqual(teams?.app, "teams")
        XCTAssertEqual(teams?.chat, "Mindlinq Business & Dev")
        XCTAssertEqual(teams?.sender, "Aron")
        XCTAssertEqual(teams?.text, "Ter info")
    }

    func testTeamsOnItsNewerWebAddresses() {
        XCTAssertEqual(MessagingApps.app(mentionedIn: ["teams.cloud.microsoft", "Anna", "hoi"])?.id, "teams")
        XCTAssertEqual(MessagingApps.app(mentionedIn: ["teams.live.com", "Anna", "hoi"])?.id, "teams")
    }

    // MARK: Markup

    func testChatMarkup() {
        typealias Span = ChatFormat.Span
        XCTAssertEqual(ChatFormat.spans("a *bold* and _soft_ ~gone~ `x = 1`"), [
            Span(text: "a "), Span(text: "bold", bold: true), Span(text: " and "), Span(text: "soft", italic: true),
            Span(text: " "), Span(text: "gone", strike: true), Span(text: " "), Span(text: "x = 1", code: true)
        ])
        XCTAssertEqual(ChatFormat.spans("**strong** __em__"), [Span(text: "strong", bold: true), Span(text: " "), Span(text: "em", italic: true)])
        XCTAssertEqual(ChatFormat.spans("5 * 3 * 2"), [Span(text: "5 * 3 * 2")], "a marker needs a word right inside it")
        XCTAssertEqual(ChatFormat.spans("file_name_here"), [Span(text: "file_name_here")], "never inside a word")
        XCTAssertEqual(ChatFormat.spans("see https://x.com/_a_b_ now"), [Span(text: "see https://x.com/_a_b_ now")],
                       "a web address stays whole")
        XCTAssertEqual(ChatFormat.spans("*_both_*"), [Span(text: "both", bold: true, italic: true)])
        XCTAssertEqual(ChatFormat.spans("*open"), [Span(text: "*open")], "an unclosed marker stays")
    }

    func testChatBlocks() {
        let text = "Release notes:\n• faster sync\n- fewer crashes\n2. done\n> quoted line\n> and more\n```\nlet x = 1\n```\nThanks"
        XCTAssertEqual(ChatFormat.blocks(text), [
            .paragraph([.init(text: "Release notes:")]),
            .item("•", [.init(text: "faster sync")]),
            .item("•", [.init(text: "fewer crashes")]),
            .item("2.", [.init(text: "done")]),
            .quote([.init(text: "quoted line\nand more")]),
            .code("let x = 1"),
            .paragraph([.init(text: "Thanks")])
        ])
        XCTAssertEqual(ChatFormat.blocks("```inline code``` after"), [.code("inline code"), .paragraph([.init(text: "after")])])
        XCTAssertEqual(ChatFormat.plain("*Hi* _there_\n• one"), "Hi there\n• one")
        XCTAssertEqual(InboxMessage(id: "a", text: "*Done*", date: now).summary, "Done", "a list line shows no markup")
    }

    func testSlackAppMessagesShowTheirAttachments() {
        let conversation = SlackData.Conversation(id: "D1", user: "U1", name: "", isGroup: false, updated: 0)
        let history: [String: Any] = ["messages": [["ts": "1700000001.000100", "bot_id": "B1", "text": "", "attachments": [
            ["pretext": "New push to <https://github.com/acme/app|acme/app>", "title": "main", "text": "Fix the build"],
            ["fallback": "Workflow passed"]
        ]]]]
        let messages = SlackData.messages(history, conversation: conversation, users: [:], me: "U2")
        XCTAssertEqual(messages.first?.text, "New push to acme/app\nmain\nFix the build\n\nWorkflow passed")
    }

    // MARK: Polls

    func testVotingOnAPoll() {
        let one = ChatPoll(question: "Lunch?", options: [.init(text: "Pizza", votes: 2), .init(text: "Sushi", votes: 1, chosen: true)])
        XCTAssertEqual(one.choice(afterTapping: "Pizza"), ["Pizza"], "one answer: a new one replaces yours")
        XCTAssertEqual(one.choice(afterTapping: "Sushi"), [], "a second click takes it back")
        let moved = one.voting(["Pizza"])
        XCTAssertEqual(moved.options.map(\.votes), [3, 0])
        XCTAssertEqual(moved.chosen, ["Pizza"])
        var many = one
        many.multiple = true
        XCTAssertEqual(many.choice(afterTapping: "Pizza"), ["Sushi", "Pizza"])
        XCTAssertEqual(InboxMessage(id: "p", text: "", date: now, poll: one).summary, "📊 Lunch?")
    }

    func testTelegramPolls() {
        let content: [String: Any] = ["@type": "messagePoll", "poll": [
            "question": ["text": "Where?"], "type": ["@type": "pollTypeRegular", "allow_multiple_answers": true],
            "options": [["text": ["text": "Here"], "voter_count": 3, "is_chosen": true], ["text": "There", "voter_count": 1]]
        ]]
        XCTAssertEqual(TelegramData.poll(content), ChatPoll(question: "Where?", options: [
            .init(text: "Here", votes: 3, chosen: true), .init(text: "There", votes: 1)
        ], multiple: true))
        let chat = TelegramData.Chat(id: -100123, title: "Club", isGroup: true, unread: 0, order: 0)
        let message = TelegramData.message(["@type": "message", "id": 45, "date": 1_700_000_000, "content": content],
                                           chat: chat, users: [:])
        XCTAssertEqual(message?.text, "")
        XCTAssertEqual(message?.poll?.question, "Where?")
        XCTAssertEqual(TelegramData.ids("telegram--100123-45")?.chat, -100123)
        XCTAssertEqual(TelegramData.ids("telegram--100123-45")?.message, 45)
        XCTAssertNil(TelegramData.ids("slack-C1-1"))
    }

    // MARK: Files in chats

    func testWhatAFileIs() {
        XCTAssertEqual(ChatMedia.kind(mimeType: "image/jpeg"), .photo)
        XCTAssertEqual(ChatMedia.kind(mimeType: "image/gif"), .gif)
        XCTAssertEqual(ChatMedia.kind(mimeType: "video/mp4", gif: true), .gif, "a GIF that came as a video is a GIF")
        XCTAssertEqual(ChatMedia.kind(mimeType: "image/webp", sticker: true), .sticker)
        XCTAssertEqual(ChatMedia.kind(mimeType: "audio/ogg", voice: true), .voice)
        XCTAssertEqual(ChatMedia.kind(mimeType: nil, name: "song.mp3"), .audio)
        XCTAssertEqual(ChatMedia.kind(mimeType: nil, name: "IMG_0001.HEIC"), .photo)
        XCTAssertEqual(ChatMedia.kind(mimeType: "application/pdf", name: "plan.pdf"), .file)
        XCTAssertEqual(ChatMedia(kind: .file, name: "plan.pdf").label, "plan.pdf")
        XCTAssertEqual(ChatMedia(kind: .sticker).label, tr("chat.media.sticker"))
    }

    func testAFetchedFileStaysInItsFolder() {
        let url = ChatMedia.destination(key: "slack-C1-17.1", name: "../../evil/x.png")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().path, ChatMedia.folder.path)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
    }

    func testAFileLaterFetchedShowsInItsMessage() {
        var inbox = ChatInbox()
        let key = ChatInbox.key(app: "telegram", chat: "Anna")
        var photo = InboxMessage(id: "t1", text: "", date: now, media: ChatMedia(kind: .photo))
        inbox.merge(BridgedChat(app: "telegram", name: "Anna", messages: [photo], unread: 0))
        photo.media?.path = "/tmp/photo.jpg"
        XCTAssertTrue(inbox.merge(BridgedChat(app: "telegram", name: "Anna", messages: [photo], unread: 0)))
        XCTAssertEqual(inbox.threads[key]?.messages.first?.media?.path, "/tmp/photo.jpg")
        XCTAssertEqual(inbox.threads[key]?.messages.first?.summary, tr("whatsapp.file.photo"))
    }

    func testTwoPhotosInARowAreTwoMessages() {
        var inbox = ChatInbox()
        let photos = [InboxMessage(id: "a", text: "", date: now, media: ChatMedia(kind: .photo)),
                      InboxMessage(id: "b", text: "", date: now.addingTimeInterval(2), media: ChatMedia(kind: .photo))]
        inbox.merge(BridgedChat(app: "messages", name: "Anna", messages: photos, unread: 0))
        XCTAssertEqual(inbox.threads[ChatInbox.key(app: "messages", chat: "Anna")]?.messages.count, 2)
    }

    func testAChatKeepsItsPicture() {
        var inbox = ChatInbox()
        let key = ChatInbox.key(app: "telegram", chat: "Family")
        inbox.merge(BridgedChat(app: "telegram", name: "Family", messages: [message("a", "hi")], unread: 0))
        XCTAssertNil(inbox.threads[key]?.avatar)
        XCTAssertTrue(inbox.merge(BridgedChat(app: "telegram", name: "Family", messages: [], unread: nil, avatar: "/tmp/family.jpg")),
                      "a picture alone changes the chat")
        XCTAssertEqual(inbox.threads[key]?.avatar, "/tmp/family.jpg")
        inbox.merge(BridgedChat(app: "telegram", name: "Family", messages: [message("b", "again", at: 5)], unread: 0))
        XCTAssertEqual(inbox.threads[key]?.avatar, "/tmp/family.jpg", "a read without a picture keeps the one it has")
    }

    func testTelegramFiles() {
        let sticker: [String: Any] = ["@type": "messageSticker", "sticker": [
            "emoji": "😀", "format": ["@type": "stickerFormatWebp"],
            "sticker": ["@type": "file", "id": 7, "size": 20_000, "local": ["path": "", "is_downloading_completed": false]]]]
        let file = TelegramData.file(sticker)
        XCTAssertEqual(file?.id, 7)
        XCTAssertEqual(file?.media.kind, .sticker)
        XCTAssertNil(file?.media.path)
        let voice: [String: Any] = ["@type": "messageVoiceNote", "voice_note": [
            "duration": 4, "voice": ["@type": "file", "id": 8, "size": 9_000,
                                     "local": ["path": "/tmp/v.oga", "is_downloading_completed": true]]]]
        XCTAssertEqual(TelegramData.file(voice)?.media, ChatMedia(kind: .voice, path: "/tmp/v.oga", seconds: 4))
        let gif: [String: Any] = ["@type": "messageAnimation", "caption": ["text": "lol"],
                                  "animation": ["animation": ["@type": "file", "id": 9, "size": 1]]]
        XCTAssertEqual(TelegramData.file(gif)?.media.kind, .gif)
        let chat = TelegramData.Chat(id: -5, title: "Family", isGroup: true, unread: 0, order: 0)
        let message = TelegramData.message(["@type": "message", "id": 3, "date": 1_700_000_000, "content": gif], chat: chat, users: [:])
        XCTAssertEqual(message?.text, "lol", "a file's caption is its text")
        XCTAssertEqual(message?.media?.kind, .gif)
        let group = TelegramData.chat(["@type": "chat", "id": -7, "title": "Club", "type": ["@type": "chatTypeBasicGroup"],
                                       "photo": ["small": ["@type": "file", "id": 11, "local": ["path": "/tmp/club.jpg", "is_downloading_completed": true]]]])
        XCTAssertEqual(group?.photo, 11)
        XCTAssertEqual(group?.avatar, "/tmp/club.jpg")
    }

    func testSlackAndBeeperFiles() {
        let clip = SlackData.file(["name": "clip.m4a", "mimetype": "audio/mp4", "subtype": "slack_audio", "duration_ms": 3500,
                                   "url_private_download": "https://files.slack.com/files-pri/T1-F1/download/clip.m4a"])
        XCTAssertEqual(clip?.kind, .voice)
        XCTAssertEqual(clip?.seconds, 3.5)
        XCTAssertTrue(SlackData.isSlack(URL(string: "https://files.slack.com/x")!))
        XCTAssertFalse(SlackData.isSlack(URL(string: "https://files.slack.com.evil.com/x")!), "the token never leaves Slack")
        XCTAssertFalse(SlackData.isSlack(URL(string: "http://files.slack.com/x")!))
        XCTAssertNil(SlackData.file(["name": "big.mov", "size": 900_000_000, "url_private": "https://files.slack.com/big"])?.source)
        XCTAssertEqual(SlackData.avatars(["members": [["id": "U1", "profile": ["image_72": "https://avatars.slack-edge.com/a.png"]]]]),
                       ["U1": "https://avatars.slack-edge.com/a.png"])

        let gif = BeeperData.file(["type": "img", "mimeType": "video/mp4", "isGif": true, "srcURL": "file:///tmp/a.mp4"])
        XCTAssertEqual(gif?.kind, .gif)
        XCTAssertEqual(gif?.path, "/tmp/a.mp4")
        let photo = BeeperData.file(["type": "img", "srcURL": "mxc://beeper.com/abc", "fileName": "a"])
        XCTAssertEqual(photo?.kind, .photo)
        XCTAssertEqual(photo?.source, "mxc://beeper.com/abc")
        XCTAssertEqual(BeeperData.picture(["type": "single", "participants": ["items": [
            ["isSelf": true, "imgURL": "file:///me.jpg"], ["imgURL": "file:///anna.jpg"]]]]), "file:///anna.jpg")
        XCTAssertNil(BeeperData.picture(["type": "group", "participants": ["items": [["imgURL": "file:///anna.jpg"]]]]))
    }

    // MARK: Slack

    func testSlackMarkup() {
        let users = ["U1": "Anna"]
        XCTAssertEqual(SlackData.clean("hi <@U1>, see <#C1|general> and <https://x.com|this> &amp; <https://y.com>", users: users),
                       "hi @Anna, see #general and this & https://y.com")
        XCTAssertEqual(SlackData.clean("<!here> lunch?", users: [:]), "@here lunch?")
    }

    func testSlackConversationsAndNames() {
        let list: [String: Any] = ["ok": true, "channels": [
            ["id": "D1", "is_im": true, "user": "U1", "created": 100.0],
            ["id": "G1", "is_mpim": true, "name": "mpdm-anna--jan--me-1", "updated": 1_700_000_000_000.0],
            ["id": "C1", "is_channel": true, "name": "general"],
            ["id": "D2", "is_im": true, "user": "U9", "is_user_deleted": true]
        ]]
        let conversations = SlackData.conversations(list)
        XCTAssertEqual(conversations.map(\.id), ["D1", "G1"])
        XCTAssertEqual(conversations[1].updated, 1_700_000_000, "milliseconds to seconds")
        let users = SlackData.users(["members": [
            ["id": "U1", "name": "anna", "profile": ["display_name": "", "real_name": "Anna Smit"]],
            ["id": "U2", "name": "me", "profile": ["display_name": "me"]]
        ]])
        XCTAssertEqual(users["U1"], "Anna Smit")
        XCTAssertEqual(SlackData.chatName(conversations[0], users: users, me: "U2"), "Anna Smit")
        XCTAssertEqual(SlackData.chatName(conversations[1], users: users, me: "U2"), "anna, jan")
    }

    func testSlackHistory() {
        let group = SlackData.Conversation(id: "G1", user: nil, name: "mpdm-a--b-1", isGroup: true, updated: 0)
        let history: [String: Any] = ["ok": true, "messages": [
            ["ts": "1700000020.000200", "user": "U2", "text": "mine"],
            ["ts": "1700000010.000100", "user": "U1", "text": "hello"],
            ["ts": "1700000005.000100", "user": "U1", "subtype": "channel_join", "text": "joined"],
            ["ts": "1700000001.000100", "user": "U1", "text": "", "files": [["name": "plan.pdf"]]]
        ]]
        let messages = SlackData.messages(history, conversation: group, users: ["U1": "Anna"], me: "U2")
        XCTAssertEqual(messages.map(\.summary), ["plan.pdf", "hello", "mine"])
        XCTAssertEqual(messages[0].text, "", "a file without a message has no text of its own")
        XCTAssertEqual(messages[0].media?.kind, .file)
        XCTAssertEqual(messages[1].sender, "Anna")
        XCTAssertTrue(messages[2].isMine)
        XCTAssertEqual(messages[2].sender, "")
        XCTAssertEqual(messages[1].id, "slack-G1-1700000010.000100")
        XCTAssertEqual(SlackData.error(["ok": false, "error": "invalid_auth"]), "invalid_auth")
        XCTAssertNil(SlackData.error(["ok": true]))
    }

    // MARK: Telegram

    func testTelegramChatsAndLogin() {
        let group = TelegramData.chat(["@type": "chat", "id": -100123, "title": "Family", "unread_count": 2,
                                       "type": ["@type": "chatTypeSupergroup", "is_channel": false],
                                       "positions": [["@type": "chatPosition", "list": ["@type": "chatListMain"], "order": "42"]]])
        XCTAssertEqual(group, TelegramData.Chat(id: -100123, title: "Family", isGroup: true, unread: 2, order: 42))
        XCTAssertNil(TelegramData.chat(["@type": "chat", "id": 1, "title": "News",
                                        "type": ["@type": "chatTypeSupergroup", "is_channel": true]]), "a channel is no chat")
        XCTAssertEqual(TelegramData.chat(["@type": "chat", "id": 7, "title": "Anna", "type": ["@type": "chatTypePrivate"]])?.isGroup, false)
        XCTAssertEqual(TelegramData.authorization(["@type": "updateAuthorizationState",
                                                   "authorization_state": ["@type": "authorizationStateWaitCode",
                                                                           "code_info": ["phone_number": "+31612345678"]]]),
                       .code(phone: "+31612345678"))
        XCTAssertEqual(TelegramData.authorization(["@type": "authorizationStateReady"]), .ready)
        XCTAssertEqual(TelegramData.userName(["@type": "user", "first_name": "Anna", "last_name": "Smit"]), "Anna Smit")
        XCTAssertEqual(TelegramData.userName(["@type": "user", "first_name": "", "usernames": ["active_usernames": ["anna"]]]), "@anna")
    }

    func testTelegramMessages() {
        let chat = TelegramData.Chat(id: -5, title: "Family", isGroup: true, unread: 0, order: 0)
        let text: [String: Any] = ["@type": "message", "id": 10, "date": 1_700_000_000, "is_outgoing": false,
                                   "sender_id": ["@type": "messageSenderUser", "user_id": 3],
                                   "content": ["@type": "messageText", "text": ["@type": "formattedText", "text": " dinner? "]]]
        let message = TelegramData.message(text, chat: chat, users: [3: "Jan"])
        XCTAssertEqual(message?.text, "dinner?")
        XCTAssertEqual(message?.sender, "Jan")
        XCTAssertEqual(message?.id, "telegram--5-10")
        XCTAssertEqual(message?.isMine, false)
        var mine = text
        mine["is_outgoing"] = true
        XCTAssertEqual(TelegramData.message(mine, chat: chat, users: [3: "Jan"])?.sender, "", "your own message has no sender")
        XCTAssertEqual(TelegramData.text(["@type": "messagePhoto", "caption": ["text": "beach"]]), tr("whatsapp.file.photo") + ": beach")
        XCTAssertEqual(TelegramData.text(["@type": "messageDocument", "document": ["file_name": "plan.pdf"]]), "plan.pdf")
        XCTAssertNil(TelegramData.text(["@type": "messagePinMessage"]), "a service message shows nothing")
        XCTAssertEqual(TelegramData.request(["@type": "getMe"]), #"{"@type":"getMe"}"#)
    }

    // MARK: Teams

    func testTeamsSignInAnswers() {
        let code = TeamsData.deviceCode(["device_code": "D", "user_code": "ABCD-EFGH", "interval": 5, "expires_in": 900,
                                         "verification_uri": "https://microsoft.com/devicelogin"], now: now)
        XCTAssertEqual(code?.userCode, "ABCD-EFGH")
        XCTAssertEqual(code?.expires, now.addingTimeInterval(900))
        XCTAssertEqual(TeamsData.token(["error": "authorization_pending"]), .pending(slowDown: false))
        XCTAssertEqual(TeamsData.token(["error": "slow_down"]), .pending(slowDown: true))
        XCTAssertEqual(TeamsData.token(["access_token": "A", "refresh_token": "R", "expires_in": 60], now: now),
                       .token(access: "A", refresh: "R", expires: now.addingTimeInterval(60)))
        XCTAssertEqual(TeamsData.token(["error": "expired_token", "error_description": "AADSTS70020: expired\r\nTrace ID: x"]),
                       .failed("AADSTS70020: expired"))
        XCTAssertEqual(String(data: TeamsData.form(["scope": "Chat.Read offline_access", "a": "b&c"]), encoding: .utf8),
                       "a=b%26c&scope=Chat.Read%20offline_access")
    }

    func testTeamsChatsAndMessages() {
        let list: [String: Any] = ["value": [
            ["id": "1", "chatType": "oneOnOne", "members": [["userId": "me", "displayName": "Me"], ["userId": "u1", "displayName": "Anna"]],
             "lastMessagePreview": ["createdDateTime": "2026-10-22T09:00:00.123Z"],
             "viewpoint": ["lastMessageReadDateTime": "2026-10-22T08:00:00Z"]],
            ["id": "2", "chatType": "group", "topic": "Launch", "members": []],
            ["id": "3", "chatType": "meeting", "topic": "", "members": [["userId": "u2", "displayName": "Jan"]]],
            ["id": "4", "chatType": "oneOnOne", "members": [["userId": "u3", "displayName": "Lisa"]], "viewpoint": ["isHidden": true]]
        ]]
        let chats = TeamsData.chats(list, me: "me")
        XCTAssertEqual(chats.map(\.name), ["Anna", "Launch"], "a meeting without a topic and a hidden chat are left out")
        XCTAssertNotNil(chats[0].last)
        let history: [String: Any] = ["value": [
            ["id": "m2", "messageType": "message", "createdDateTime": "2026-10-22T09:00:00Z",
             "from": ["user": ["id": "u1", "displayName": "Anna"]], "body": ["contentType": "html", "content": "<p>Hi &amp; welcome</p><p>to</p>"]],
            ["id": "m1", "messageType": "message", "createdDateTime": "2026-10-22T07:00:00Z",
             "from": ["user": ["id": "me"]], "body": ["contentType": "text", "content": "morning"]],
            ["id": "s1", "messageType": "systemEventMessage", "createdDateTime": "2026-10-22T07:30:00Z", "body": ["content": ""]]
        ]]
        let messages = TeamsData.messages(history, chat: chats[0], me: "me")
        XCTAssertEqual(messages.map(\.text), ["morning", "Hi & welcome\nto"])
        XCTAssertTrue(messages[0].isMine)
        XCTAssertEqual(messages[1].sender, "", "a private chat needs no sender")
        XCTAssertEqual(TeamsData.unread(messages, readUntil: chats[0].readUntil), 1)
    }

    func testTeamsChatReadBeforeGraphListsItsNewestMessage() {
        let last = TeamsData.date("2026-10-22T09:00:00.123Z")
        let early: [String: Any] = ["value": [["id": "m1", "createdDateTime": "2026-10-22T08:59:00Z"]]]
        XCTAssertFalse(TeamsData.caughtUp(early, last: last), "the announced message is not listed yet: read the chat again")
        XCTAssertFalse(TeamsData.caughtUp(["value": []], last: last))
        let listed: [String: Any] = ["value": [["id": "m2", "createdDateTime": "2026-10-22T09:00:00Z"], ["id": "m1", "createdDateTime": "2026-10-22T08:59:00Z"]]]
        XCTAssertTrue(TeamsData.caughtUp(listed, last: last), "the same moment without its milliseconds")
        let notice: [String: Any] = ["value": [["id": "s1", "messageType": "systemEventMessage", "createdDateTime": "2026-10-22T09:00:00.123Z"]]]
        XCTAssertTrue(TeamsData.caughtUp(notice, last: last), "a system notice the list announced counts too")
        XCTAssertTrue(TeamsData.caughtUp(early, last: nil))
    }

    // MARK: Beeper

    func testBeeperNetworksGoToTheirApps() {
        XCTAssertEqual(BeeperData.app(network: "Instagram", account: "instagramgo"), "instagram")
        XCTAssertEqual(BeeperData.app(network: "Facebook/Messenger", account: "facebookgo"), "messenger")
        XCTAssertEqual(BeeperData.app(network: "", account: "discordgo"), "discord")
        XCTAssertEqual(BeeperData.app(network: "Twitter/X", account: "twitter"), "x")
        XCTAssertEqual(BeeperData.app(network: "Signal", account: "signal"), "signal")
        XCTAssertNil(BeeperData.app(network: "Google Messages", account: "gmessages"), "a network without a source is left out")
    }

    func testBeeperChatsAndMessages() {
        let list: [String: Any] = ["items": [
            ["id": "!a:beeper.local", "accountID": "instagramgo", "network": "Instagram", "title": "Anna", "type": "single",
             "unreadCount": 2, "lastActivity": "2026-10-22T09:00:00.000Z"],
            ["id": "!b", "accountID": "discordgo", "title": "Gamers", "type": "group", "isArchived": true],
            ["id": "!c", "accountID": "gmessages", "title": "Bank", "type": "single"]
        ]]
        let chats = BeeperData.chats(list)
        XCTAssertEqual(chats.map(\.app), ["instagram"])
        XCTAssertEqual(chats.first?.unread, 2)
        let group = BeeperData.Chat(id: "!g", app: "discord", title: "Gamers", isGroup: true, unread: 0, last: nil)
        let history: [String: Any] = ["items": [
            ["id": "2", "timestamp": "2026-10-22T09:00:00Z", "text": "gg", "senderName": "Jan", "isSender": false],
            ["id": "1", "timestamp": "2026-10-22T08:00:00Z", "text": "", "type": "IMAGE", "isSender": true],
            ["id": "3", "timestamp": "2026-10-22T09:01:00Z", "text": "👍", "type": "REACTION"]
        ]]
        let messages = BeeperData.messages(history, chat: group)
        XCTAssertEqual(messages.map(\.text), [tr("whatsapp.file.photo"), "gg"])
        XCTAssertTrue(messages[0].isMine)
        XCTAssertEqual(messages[1].sender, "Jan")
        XCTAssertEqual(messages[1].id, "beeper-!g-2")
    }

    // MARK: As bubbles

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testRunsByOneAuthor() {
        let items = [
            ChatTimeline.Item(id: "a", author: "Jan", date: now),
            ChatTimeline.Item(id: "b", author: "Jan", date: now.addingTimeInterval(30)),
            ChatTimeline.Item(id: "c", author: "Anna", date: now.addingTimeInterval(40)),
            ChatTimeline.Item(id: "d", author: "Anna", date: now.addingTimeInterval(40 + ChatTimeline.runGap + 1))
        ]
        XCTAssertEqual(ChatTimeline.entries(items, now: now, calendar: calendar), [
            .message(id: "a", first: true, last: false),
            .message(id: "b", first: false, last: true),
            .message(id: "c", first: true, last: true),
            .message(id: "d", first: true, last: true)
        ])
    }

    func testADayLineWhereANewDayStarts() {
        let yesterday = now.addingTimeInterval(-86_400)
        let items = [
            ChatTimeline.Item(id: "a", author: "Jan", date: yesterday),
            ChatTimeline.Item(id: "b", author: "Jan", date: now)
        ]
        XCTAssertEqual(ChatTimeline.entries(items, now: now, calendar: calendar), [
            .day(id: "day-a", label: tr("chat.day.yesterday")),
            .message(id: "a", first: true, last: true),
            .day(id: "day-b", label: tr("chat.day.today")),
            .message(id: "b", first: true, last: true)
        ])
    }

    func testNoDayLineWhenEverythingIsFromToday() {
        let items = [ChatTimeline.Item(id: "a", author: "Jan", date: now), ChatTimeline.Item(id: "b", author: "", date: nil)]
        XCTAssertEqual(ChatTimeline.entries(items, now: now, calendar: calendar), [
            .message(id: "a", first: true, last: true),
            .message(id: "b", first: true, last: true)
        ])
    }

    func testDayLabels() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(ChatTimeline.dayLabel(now, now: now, calendar: calendar, locale: locale), tr("chat.day.today"))
        XCTAssertEqual(ChatTimeline.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale),
                       tr("chat.day.yesterday"))
        let threeDaysAgo = ChatTimeline.dayLabel(now.addingTimeInterval(-3 * 86_400), now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(threeDaysAgo.contains(where: \.isNumber), "a weekday: \(threeDaysAgo)")
        let longAgo = ChatTimeline.dayLabel(now.addingTimeInterval(-400 * 86_400), now: now, calendar: calendar, locale: locale)
        XCTAssertTrue(longAgo.contains("2025"), "another year names it: \(longAgo)")
    }

    func testEmojiOnly() {
        XCTAssertTrue(ChatTimeline.isEmojiOnly("😂"))
        XCTAssertTrue(ChatTimeline.isEmojiOnly("👍🏽 ❤️"))
        XCTAssertTrue(ChatTimeline.isEmojiOnly("👨‍👩‍👧"))
        XCTAssertFalse(ChatTimeline.isEmojiOnly("ok 👍"))
        XCTAssertFalse(ChatTimeline.isEmojiOnly("😂😂😂😂"))
        XCTAssertFalse(ChatTimeline.isEmojiOnly("1"))
        XCTAssertFalse(ChatTimeline.isEmojiOnly(""))
    }

    func testColorPerPerson() {
        XCTAssertEqual(ChatTimeline.colorIndex(for: "Jan", count: 6), ChatTimeline.colorIndex(for: "jan", count: 6))
        XCTAssertTrue((0..<6).contains(ChatTimeline.colorIndex(for: "Anna", count: 6)))
        XCTAssertEqual(ChatTimeline.colorIndex(for: "Anna", count: 0), 0)
        let spread = Set(["Anna", "Jan", "Piet", "Klaas", "Mies", "Bram", "Sara", "Tom"].map { ChatTimeline.colorIndex(for: $0, count: 6) })
        XCTAssertGreaterThan(spread.count, 2)
    }

    // MARK: For Nook's answers

    func testFindsAChatByName() {
        var inbox = ChatInbox()
        inbox.add(notice("Anna de Vries", "hi"), id: "1")
        inbox.add(notice("Annabel", "yo", at: 10), id: "2")
        inbox.add(notice("Família", "jantar", app: "signal", at: 20), id: "3")
        XCTAssertEqual(inbox.thread(named: "annabel")?.name, "Annabel", "exact first")
        XCTAssertEqual(inbox.thread(named: "Anna de")?.name, "Anna de Vries")
        XCTAssertEqual(inbox.thread(named: "familia")?.app, "signal", "without accents")
        XCTAssertNil(inbox.thread(named: "familia", app: "telegram"))
        XCTAssertNil(inbox.thread(named: "  "))
    }

    func testOverviewAndTranscript() {
        var inbox = ChatInbox()
        inbox.add(notice("Family", "dinner?", sender: "Jan"), id: "1")
        let thread = inbox.sorted[0]
        let overview = ChatInbox.overview(inbox.sorted)
        XCTAssertTrue(overview.hasPrefix("- Telegram · Family (1 unread) · "), overview)
        XCTAssertTrue(overview.hasSuffix(" · Jan: dinner?"), overview)
        XCTAssertTrue(ChatInbox.transcript(thread).hasSuffix("] Jan: dinner?"))
    }
}

private extension ChatSources.Added {
    var isKnown: Bool {
        if case .known = self { return true }
        return false
    }
}
