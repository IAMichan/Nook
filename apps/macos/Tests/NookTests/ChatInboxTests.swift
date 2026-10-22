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
            .day(id: "day-a", label: "chat.day.yesterday"),
            .message(id: "a", first: true, last: true),
            .day(id: "day-b", label: "chat.day.today"),
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
        XCTAssertEqual(ChatTimeline.dayLabel(now, now: now, calendar: calendar, locale: locale), "chat.day.today")
        XCTAssertEqual(ChatTimeline.dayLabel(now.addingTimeInterval(-86_400), now: now, calendar: calendar, locale: locale),
                       "chat.day.yesterday")
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
