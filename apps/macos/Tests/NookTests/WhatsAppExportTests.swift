import XCTest

/// WhatsApp's chats as every chat app's (`WhatsAppExport`): what the Chats tab, the cards and search show of a linked
/// phone's chat comes out of here, so each thing the WhatsApp bubbles showed before must come through: who wrote it, who
/// read it, who put which emoji there, who voted what, what a message answers, its file, and where the chat stands.
final class WhatsAppExportTests: XCTestCase {
    private let group = "120363000000000001@g.us"
    private let anna = "31611111111@s.whatsapp.net"
    private let bob = "31622222222@s.whatsapp.net"

    private func message(_ id: String, chat: String, from: String? = nil, text: String = "hoi", at: Double = 0,
                         fromMe: Bool = false, name: String = "") -> WAMessage {
        WAMessage(id: id, chat: chat, sender: from ?? chat, senderName: name, text: text,
                  date: Date(timeIntervalSince1970: 1_800_000_000 + at), fromMe: fromMe)
    }

    private func groupChat(_ messages: [WAMessage], members: [WAMember]? = nil) -> WAConversation {
        WAConversation(id: group, name: "Family", isGroup: true, messages: messages,
                       lastActivity: messages.last?.date ?? Date(timeIntervalSince1970: 1_800_000_000), members: members)
    }

    private func export(_ conversation: WAConversation, facts: WhatsAppExport.Facts? = nil,
                        names: WANameBook = WANameBook()) -> BridgedChat {
        WhatsAppExport.chat(conversation, facts: facts ?? WhatsAppExport.Facts(key: conversation.id), names: names)
    }

    func testAGroupsMessagesSayWhoWroteThemByName() {
        var mine = message("2", chat: group, text: "on my way", at: 2, fromMe: true)
        mine.receipt = .sent
        var mention = message("3", chat: group, from: bob, text: "@me", at: 3, name: "Bobby")
        mention.mentionsMe = true
        let chat = export(groupChat([message("1", chat: group, from: anna, at: 1, name: "Anna"), mine, mention],
                                    members: [WAMember(ids: [anna], name: "Anna K."), WAMember(ids: [bob], name: "")]))
        XCTAssertEqual(chat.kind, .group)
        XCTAssertEqual(chat.messages.map(\.sender), ["Anna K.", "", "Bobby"], "the member's name, else the one they wrote under")
        XCTAssertEqual(chat.messages.map(\.isMine), [false, true, false])
        XCTAssertEqual(chat.messages[2].mentionsMe, true)
        XCTAssertEqual(chat.messages[0].senderID, anna)
        XCTAssertNil(chat.messages[1].senderID)
        XCTAssertEqual(chat.members, ["Anna K.", "Bobby"])
        XCTAssertNil(chat.handle, "a group has no number")
    }

    func testAPersonsChatIsCalledAfterThem() {
        let person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [message("1", chat: anna, name: "Anna")],
                                    lastActivity: Date(timeIntervalSince1970: 1_800_000_000))
        let chat = export(person)
        XCTAssertEqual(chat.name, "Anna")
        XCTAssertEqual(chat.kind, .person)
        XCTAssertEqual(chat.handle, anna, "its number finds the picture in Contacts")
        XCTAssertEqual(chat.messages.first?.sender, "", "in a private chat the chat's name says who")
        XCTAssertNil(chat.members)
    }

    func testEveryEmojiSaysWhoPutItThere() {
        var liked = message("1", chat: group, from: anna, name: "Anna")
        liked.reactions = [WAReaction(emoji: "👍", sender: bob), WAReaction(emoji: "❤️", sender: anna),
                           WAReaction(emoji: "👍", sender: "", fromMe: true)]
        let chat = export(groupChat([liked], members: [WAMember(ids: [anna], name: "Anna"), WAMember(ids: [bob], name: "Bob")]))
        XCTAssertEqual(chat.messages.first?.reactions, [
            InboxReaction(emoji: "👍", count: 2, mine: true, people: ["Bob"]),
            InboxReaction(emoji: "❤️", count: 1, mine: false, people: ["Anna"]),
        ], "the most used first, yours told apart by `mine`")
        var plain = message("2", chat: anna)
        plain.reactions = [WAReaction(emoji: "😂", sender: anna)]
        let person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [plain], lastActivity: plain.date)
        XCTAssertEqual(export(person).messages.first?.reactions?.first?.people, ["Anna"], "in a private chat: the chat itself")
        XCTAssertEqual(export(groupChat([message("3", chat: group)])).messages.first?.reactions, [],
                       "none is said too, so one taken back goes")
    }

    func testAPollSaysWhoVotedWhat() {
        var poll = message("1", chat: group, from: anna, text: "", name: "Anna")
        poll.poll = WAPoll(question: "Dinner?", options: ["Pizza", "Sushi"], votes: [bob: ["Sushi"], WAPoll.me: ["Pizza"]])
        let chat = export(groupChat([poll], members: [WAMember(ids: [bob], name: "Bob")]))
        let shown = chat.messages.first?.poll
        XCTAssertEqual(shown?.question, "Dinner?")
        XCTAssertEqual(shown?.options.map(\.votes), [1, 1])
        XCTAssertEqual(shown?.options.map(\.chosen), [true, false])
        XCTAssertEqual(shown?.options.last?.voters, ["Bob"])
    }

    func testAnAnswerQuotesWhatItAnswers() {
        var answer = message("2", chat: anna, at: 1)
        answer.replyTo = "1"
        answer.quotedText = "lunch?"
        let person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [message("1", chat: anna), answer],
                                    lastActivity: answer.date)
        XCTAssertEqual(export(person).messages.last?.quote, InboxQuote(id: "1", text: "lunch?"))
        XCTAssertNil(export(person).messages.first?.quote)
    }

    func testFilesComeAsEveryAppsWithWhatTheLinkFetched() {
        var photo = message("1", chat: anna, text: "beach")
        photo.media = .image
        var document = message("2", chat: anna, text: "")
        document.media = .document(name: "plan.pdf")
        var voice = message("3", chat: anna, text: "")
        voice.media = .voice(seconds: 12)
        var place = message("4", chat: anna, text: "Home")
        place.media = .location
        var card = message("5", chat: anna, text: "")
        card.media = .contact
        let person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [photo, document, voice, place, card],
                                    lastActivity: card.date)
        var facts = WhatsAppExport.Facts(key: anna)
        facts.files = ["1": "/tmp/beach.jpg"]
        let messages = export(person, facts: facts).messages
        XCTAssertEqual(messages[0].media, ChatMedia(kind: .photo, path: "/tmp/beach.jpg"))
        XCTAssertEqual(messages[0].text, "beach", "a caption stays the text")
        XCTAssertEqual(messages[1].media, ChatMedia(kind: .file, name: "plan.pdf"))
        XCTAssertEqual(messages[2].media, ChatMedia(kind: .voice, seconds: 12))
        XCTAssertNil(messages[3].media)
        XCTAssertTrue(messages[3].text.hasPrefix("📍 "), "a place says what it is")
        XCTAssertTrue(messages[3].text.hasSuffix(" Home"))
        XCTAssertTrue(messages[4].text.hasPrefix("👤 "))
    }

    func testYourMessagesSayWhoReadThem() {
        var mine = message("1", chat: group, text: "hi all", fromMe: true)
        mine.receipt = .delivered
        mine.readers = [anna: ChatReader(name: "", receipt: .read, date: Date(timeIntervalSince1970: 5))]
        let known = export(groupChat([mine], members: [WAMember(ids: [anna], name: "Anna"), WAMember(ids: [bob], name: "Bob")]))
        XCTAssertEqual(known.messages.first?.readers, [ChatReader(name: "Anna", receipt: .read, date: Date(timeIntervalSince1970: 5),
                                                                  key: anna)])
        XCTAssertEqual(known.messages.first?.receipt, .delivered)

        var quiet = message("2", chat: group, text: "anyone?", fromMe: true)
        quiet.receipt = .sent
        XCTAssertEqual(export(groupChat([quiet], members: [WAMember(ids: [bob], name: "Bob")])).messages.first?.readers, [],
                       "members known, nobody answered: the info lists who does not have it yet")
        XCTAssertNil(export(groupChat([quiet])).messages.first?.readers, "members unknown and nobody answered: nothing to say")

        var direct = message("3", chat: anna, text: "hi", fromMe: true)
        direct.receipt = .read
        direct.readers = [anna: ChatReader(name: "", receipt: .read, date: Date(timeIntervalSince1970: 9))]
        let person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [direct], lastActivity: direct.date)
        XCTAssertEqual(export(person).messages.first?.readers?.first?.date, Date(timeIntervalSince1970: 9),
                       "when the other person read it")
        XCTAssertNil(export(groupChat([message("4", chat: group, from: anna)])).messages.first?.readers, "theirs has none")
    }

    func testWhereTheChatStandsComesFromTheLink() {
        var facts = WhatsAppExport.Facts(key: "work~" + anna)
        facts.account = "Work"
        facts.unread = 2
        facts.waitsInApp = true
        facts.readKnown = false
        facts.avatar = "/tmp/anna.jpg"
        facts.activity = Date(timeIntervalSince1970: 1_900_000_000)
        var person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [message("1", chat: anna)],
                                    lastActivity: Date(timeIntervalSince1970: 1_800_000_000))
        person.hasOlder = false
        let chat = export(person, facts: facts)
        XCTAssertEqual(chat.chatID, "work~" + anna)
        XCTAssertEqual(chat.account, "Work")
        XCTAssertEqual(chat.unread, 2)
        XCTAssertEqual(chat.waitsInApp, true)
        XCTAssertEqual(chat.readKnown, false)
        XCTAssertEqual(chat.avatar, "/tmp/anna.jpg")
        XCTAssertEqual(chat.hasOlder, false)
        XCTAssertEqual(chat.activity, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(chat.ephemeral, "WhatsApp's messages never reach the disk")
        XCTAssertEqual(ChatInbox.key(of: chat), "whatsapp#work~" + anna)
    }

    func testAChatThePhoneListsShowsWithoutMessages() {
        var facts = WhatsAppExport.Facts(key: bob)
        facts.unread = 3
        let chat = WhatsAppExport.listed(WAChatInfo(jid: bob, name: "Bob", last: Date(timeIntervalSince1970: 1_700_000_000), unread: 3),
                                         name: "Bob", facts: facts)
        XCTAssertTrue(chat.listed)
        XCTAssertEqual(chat.messages, [])
        XCTAssertEqual(chat.unread, 3)
        XCTAssertEqual(chat.activity, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(chat.kind, .person)
        XCTAssertTrue(chat.ephemeral)
        var inbox = ChatInbox()
        XCTAssertTrue(inbox.merge(chat))
        XCTAssertEqual(inbox.threads["whatsapp#" + bob]?.unread, 3)
    }

    func testAnExportedChatLandsInTheSharedInboxAsItWas() {
        var first = message("1", chat: anna, at: 1)
        first.mentionsMe = false
        var person = WAConversation(id: anna, name: "Anna", isGroup: false, messages: [first], lastActivity: first.date)
        var facts = WhatsAppExport.Facts(key: anna)
        facts.unread = 1
        var inbox = ChatInbox()
        inbox.merge(export(person, facts: facts))
        let key = "whatsapp#" + anna
        XCTAssertEqual(inbox.threads[key]?.unread, 1)
        XCTAssertEqual(inbox.threads[key]?.isPrivate, true)
        // Edited on the phone: the same message with its new text.
        person.messages[0].text = "hoi!"
        inbox.merge(export(person, facts: facts))
        XCTAssertEqual(inbox.threads[key]?.messages.map(\.text), ["hoi!"])
        // Renamed in Contacts: still one chat.
        person.name = "Anna Smit"
        inbox.merge(export(person, facts: facts))
        XCTAssertEqual(inbox.threads.count, 1)
        XCTAssertEqual(inbox.threads[key]?.name, "Anna Smit")
    }

    func testAMessageGoneFromTheChatIsDeletedNotLetGo() {
        let messages = (1...4).map { InboxMessage(id: "m\($0)", text: "hi", date: Date(timeIntervalSince1970: Double($0))) }
        let before = BridgedChat(app: "whatsapp", name: "Anna", messages: Array(messages.prefix(3)), unread: nil)
        let now = BridgedChat(app: "whatsapp", name: "Anna", messages: [messages[1], messages[3]], unread: nil)
        XCTAssertEqual(WhatsAppExport.deleted(before: before, now: now), ["m3"],
                       "m1 fell off the front (the chat keeps its newest), m3 was deleted")
        XCTAssertEqual(WhatsAppExport.deleted(before: nil, now: now), [])
        XCTAssertEqual(WhatsAppExport.deleted(before: before, now: BridgedChat(app: "whatsapp", name: "Anna", messages: [], unread: nil)),
                       [], "a chat that let go of everything deleted nothing")
    }
}
