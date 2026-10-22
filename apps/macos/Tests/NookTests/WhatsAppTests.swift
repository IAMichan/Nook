import XCTest

/// WhatsApp through a local gateway: conversations in memory, what the gateways send, the webhook's signature, and who a
/// recipient means. Partly after open-source code (MIT, © 2026 Louis Raillé; see THIRD-PARTY-NOTICES.md).
final class WhatsAppTests: XCTestCase {
    private func message(_ id: String, chat: String, from: String? = nil, text: String = "hoi", at: Double = 0,
                         fromMe: Bool = false, mention: Bool = false, name: String = "Lisa") -> WAMessage {
        WAMessage(id: id, chat: chat, sender: from ?? chat, senderName: name, text: text,
                  date: Date(timeIntervalSince1970: 1_800_000_000 + at), fromMe: fromMe, mentionsMe: mention)
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
        for index in 0..<30 { inbox.add(message("m\(index)", chat: "1@s.whatsapp.net", at: Double(index + 1)), filters: WAFilters()) }
        XCTAssertEqual(inbox.conversations["1@s.whatsapp.net"]?.messages.count, WAInbox.keep)
        XCTAssertEqual(inbox.conversations["1@s.whatsapp.net"]?.messages.last?.id, "m29")
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
        XCTAssertEqual(WhatsAppLink.fileName(for: .document(name: "Guard-meting (1).pdf"), given: nil, mimeType: nil),
                       "Guard-meting (1).pdf")
        XCTAssertEqual(WhatsAppLink.fileName(for: .document(name: "../../evil/x.pdf"), given: nil, mimeType: nil), "-..-evil-x.pdf")
        XCTAssertEqual(WhatsAppLink.fileName(for: .image, given: nil, mimeType: "image/jpeg"), "photo.jpeg")
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

    func testGatewayReceipts() {
        let gowa = Data(#"{"event":"message.ack","device_id":"31699999999@s.whatsapp.net","payload":{"ids":["A1","A2"],"chat_id":"31600000001@s.whatsapp.net","from":"31600000001@s.whatsapp.net","receipt_type":"read"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: gowa),
                       .receipt(ids: ["A1", "A2"], chat: "31600000001@s.whatsapp.net", status: .read))
        // Your own phone reading their messages moves no ticks: the chat is read, in a group too.
        let own = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"31600000001@s.whatsapp.net","receipt_type":"read-self"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: own), .readElsewhere(chat: "31600000001@s.whatsapp.net"))
        let ownGroup = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","receipt_type":"read-self"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: ownGroup), .readElsewhere(chat: "1203630@g.us"))
        // One group member's receipt moves no ticks either.
        let group = Data(#"{"event":"message.ack","payload":{"ids":["A1"],"chat_id":"1203630@g.us","receipt_type":"delivered"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .gowa, body: group), .ignored)

        let openwa = Data(#"{"event":"message.ack","sessionId":"s","data":{"id":"uuid-1","messageId":"B1","status":"delivered","ack":2,"chatId":"31600000001@c.us"}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .openwa, body: openwa),
                       .receipt(ids: ["B1"], chat: "31600000001@c.us", status: .delivered))
        let failed = Data(#"{"event":"message.failed","data":{"messageId":"B2","status":"failed","ack":-1}}"#.utf8)
        XCTAssertEqual(WAWebhook.parse(kind: .openwa, body: failed), .receipt(ids: ["B2"], chat: "", status: .failed))

        XCTAssertEqual(WAReceipt.read.advanced(to: .delivered), .read)
        XCTAssertEqual(WAReceipt.read.advanced(to: .failed), .failed)
        XCTAssertNil(WAReceipt(status: "retry"))
    }
}
