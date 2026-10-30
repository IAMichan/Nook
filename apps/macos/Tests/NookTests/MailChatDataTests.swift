import XCTest

final class MailChatDataTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let work = MailChatData.Account(name: "Work", addresses: ["me@work.nl"])
    private let home = MailChatData.Account(name: "iCloud", addresses: ["me@icloud.com", "me@me.com"])

    func testAccountsAreReadWithTheirAddresses() {
        let raw = "ACC|||Work|||Me@Work.nl\nACC|||iCloud|||me@icloud.com, me@me.com\nACC||| \nnoise\n"
        XCTAssertEqual(MailChatData.accounts(raw), [work, home], "addresses lower case, a nameless account left out")
    }

    func testRowsFromTheInboxAndFromSent() {
        let raw = """
        IN|||INBOX|||101|||Offerte|||Lisa de Vries <Lisa@Example.com>|||2026-10-28T09:15:00|||false
        IN|||INBOX|||102|||Note to self|||me@work.nl|||2026-10-28T10:00:00|||true
        OUT|||Sent Items|||201|||Re: Offerte|||Lisa de Vries <lisa@example.com>|||2026-10-28T11:00:00
        IN|||INBOX|||oops|||Broken|||x@y.z|||2026-10-28T11:00:00|||true
        IN|||INBOX|||103|||No address|||Someone|||2026-10-28T11:00:00|||true
        """
        let rows = MailChatData.rows(raw, account: work, calendar: utc)
        XCTAssertEqual(rows.map(\.id), [101, 102, 201], "a row without an id or an address is left out")
        XCTAssertFalse(rows[0].read)
        XCTAssertFalse(rows[0].fromMe)
        XCTAssertTrue(rows[1].fromMe, "mail from one of your own addresses is yours")
        XCTAssertTrue(rows[2].fromMe)
        XCTAssertTrue(rows[2].read, "your own mail is read")
        XCTAssertEqual(rows[2].mailbox, "Sent Items")
        XCTAssertEqual(rows[0].date, Date(timeIntervalSince1970: 1_793_178_900))
    }

    func testAddressesAndNames() {
        XCTAssertEqual(MailChatData.address("Lisa de Vries <Lisa@Example.com>"), "lisa@example.com")
        XCTAssertEqual(MailChatData.address("bram@x.nl"), "bram@x.nl")
        XCTAssertEqual(MailChatData.address("Bram"), "")
        XCTAssertEqual(MailChatData.name("\"Lisa de Vries\" <lisa@example.com>"), "Lisa de Vries")
        XCTAssertEqual(MailChatData.name("bram@x.nl"), "bram@x.nl")
        XCTAssertEqual(MailChatData.name("<bram@x.nl>"), "bram@x.nl")
    }

    func testAMessageIsItsSubjectOverItsOwnText() {
        let body = """
        Hoi,


        Hier is de offerte.
        Groet, Lisa

        On Tue, 27 Oct 2026, Bram wrote:
        > Kun je de offerte sturen?
        """
        XCTAssertEqual(MailChatData.text(subject: " Offerte ", body: body), "*Offerte*\nHoi,\n\nHier is de offerte.\nGroet, Lisa",
                       "blank lines folded, the quoted earlier mail left out")
        XCTAssertEqual(MailChatData.text(subject: "Offerte", body: ""), "*Offerte*")
        XCTAssertEqual(MailChatData.text(subject: "", body: "Hoi"), "Hoi")
        XCTAssertEqual(MailChatData.text(subject: "", body: "Ja!\nOp di 27 okt schreef Bram:\n> vraag"), "Ja!")
        XCTAssertEqual(MailChatData.text(subject: "", body: "Ok\n\nFrom: Bram <bram@x.nl>\nSent: Tuesday"), "Ok")
    }

    func testAnAnswerHasOneRe() {
        XCTAssertEqual(MailChatData.replySubject("Offerte"), "Re: Offerte")
        XCTAssertEqual(MailChatData.replySubject("Re: Offerte"), "Re: Offerte")
        XCTAssertEqual(MailChatData.replySubject("AW: Angebot"), "AW: Angebot")
        XCTAssertEqual(MailChatData.replySubject("  "), "")
    }

    func testOneChatPerPersonPerAccount() {
        let date = { (minute: Double) in Date(timeIntervalSince1970: 1_800_000_000 + minute * 60) }
        let rows = [
            MailChatData.Row(account: "Work", mailbox: "INBOX", id: 1, subject: "Offerte", person: "Lisa de Vries <lisa@example.com>",
                             date: date(0), read: false, fromMe: false),
            MailChatData.Row(account: "Work", mailbox: "Sent", id: 2, subject: "Re: Offerte", person: "lisa@example.com",
                             date: date(5), read: true, fromMe: true),
            MailChatData.Row(account: "Work", mailbox: "INBOX", id: 3, subject: "Nog iets", person: "Lisa de Vries <lisa@example.com>",
                             date: date(10), read: false, fromMe: false),
            // The same person in another account is another chat.
            MailChatData.Row(account: "iCloud", mailbox: "INBOX", id: 4, subject: "Etentje", person: "Lisa <LISA@example.com>",
                             date: date(20), read: true, fromMe: false),
            MailChatData.Row(account: "iCloud", mailbox: "INBOX", id: 5, subject: "Weekly digest", person: "News <noreply@shop.nl>",
                             date: date(30), read: false, fromMe: false),
            // Mail to yourself is no chat.
            MailChatData.Row(account: "iCloud", mailbox: "Sent", id: 6, subject: "Todo", person: "me@me.com",
                             date: date(40), read: true, fromMe: true),
        ]
        let chats = MailChatData.chats(rows, accounts: [work, home], bodies: [1: "Zie bijlage."], named: true)
        XCTAssertEqual(chats.map(\.chatID), ["iCloud~noreply@shop.nl", "iCloud~lisa@example.com", "Work~lisa@example.com"],
                       "newest first")

        let lisa = chats[2]
        XCTAssertEqual(lisa.app, "mail")
        XCTAssertEqual(lisa.name, "Lisa de Vries")
        XCTAssertEqual(lisa.account, "Work")
        XCTAssertEqual(lisa.messages.map(\.id), ["mail-1", "mail-2", "mail-3"], "oldest first")
        XCTAssertEqual(lisa.messages[0].text, "*Offerte*\nZie bijlage.")
        XCTAssertEqual(lisa.messages.map(\.isMine), [false, true, false])
        XCTAssertEqual(lisa.messages[1].receipt, .sent)
        XCTAssertNil(lisa.messages[0].receipt)
        XCTAssertEqual(lisa.messages[0].senderID, "lisa@example.com")
        XCTAssertEqual(lisa.unread, 2)
        XCTAssertEqual(lisa.kind, .person)
        XCTAssertEqual(lisa.readKnown, true)
        XCTAssertEqual(lisa.activity, date(10))

        XCTAssertEqual(chats[0].kind, .channel, "a newsletter is a channel, quiet by default")
        XCTAssertEqual(chats[1].name, "Lisa")

        let single = MailChatData.chats(Array(rows.prefix(3)), accounts: [work], bodies: [:], named: false)
        XCTAssertNil(single.first?.account, "one account: no account name on its chats")
    }

    func testScriptsQuoteNamesAndFindMessagesById() {
        let row = MailChatData.Row(account: "Lisa \"Work\"", mailbox: "INBOX", id: 42, subject: "", person: "a@b.c",
                                   date: Date(), read: false, fromMe: false)
        XCTAssertEqual(MailChatData.reference(row), "message id 42 of mailbox \"INBOX\" of account \"Lisa \\\"Work\\\"\"")
        XCTAssertTrue(MailChatData.markReadScript([row]).contains("set read status of message id 42"))
        XCTAssertTrue(MailChatData.bodiesScript([row]).contains("<<<BODY>>>42"))
        XCTAssertTrue(MailChatData.readScript(account: "Work").contains("account \"Work\""))
        XCTAssertTrue(MailChatData.readScript(account: "Work").contains("\"Sent Items\""))
    }

    /// Every script runs inside a `with timeout` block (`SystemControl.wrapTimeout`), where AppleScript refuses a handler
    /// ("Expected “end” but found “on”").
    func testScriptsDefineNoHandlers() {
        let row = MailChatData.Row(account: "Work", mailbox: "INBOX", id: 1, subject: "", person: "a@b.c", date: Date(),
                                   read: false, fromMe: false)
        let scripts = [MailChatData.accountsScript, MailChatData.readScript(account: "Work"), MailChatData.bodiesScript([row]),
                       MailChatData.markReadScript([row])]
        for script in scripts {
            let lines = script.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            XCTAssertFalse(lines.contains { $0.hasPrefix("on ") || $0.hasPrefix("to ") }, script)
            XCTAssertFalse(script.contains("my "), script)
        }
    }

    func testMailNotificationsBecomeMailChats() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let apps = MessagingApps.builtIn
        let mail = CapturedNotification(record: 1, bundleID: "com.apple.mail", title: "Lisa de Vries", subtitle: "Offerte",
                                        body: "Hier is de offerte.", date: now)
        XCTAssertEqual(ChatCapture.notice(mail, apps: apps),
                       ChatNotice(app: "mail", chat: "Lisa de Vries", sender: "", text: "*Offerte*\nHier is de offerte.", date: now),
                       "the subject is no group member: it goes over the text")

        let outlook = CapturedNotification(record: 2, bundleID: "com.microsoft.Outlook", title: "Bram", subtitle: "Planning",
                                           body: "", date: now)
        XCTAssertEqual(ChatCapture.notice(outlook, apps: apps)?.text, "*Planning*", "a subject alone is a message too")
        XCTAssertEqual(ChatCapture.notice(outlook, apps: apps)?.app, "outlook")

        let gmail = CapturedNotification(record: 3, bundleID: "com.google.Chrome", title: "Anna", subtitle: "mail.google.com",
                                         body: "Etentje\nZaterdag om zeven?", date: now)
        let notice = ChatCapture.notice(gmail, apps: apps)
        XCTAssertEqual(notice?.app, "gmail")
        XCTAssertEqual(notice?.text, "*Etentje*\nZaterdag om zeven?", "in a browser the first line is the subject")
    }

    func testMailKeepsNewslettersQuiet() {
        let rules = ChatNoticeRules()
        XCTAssertEqual(ChatNoticeRules.kinds(of: "mail"), [.channel])
        XCTAssertTrue(rules.kindIsQuiet(.channel, app: "mail"))
        XCTAssertFalse(rules.kindIsQuiet(.person, app: "mail"))
    }
}
