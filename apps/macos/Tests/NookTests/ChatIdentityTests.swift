import XCTest

/// Who a chat is with, the same for every chat app: one number key, one name fold, and which chat a name means.
final class ChatIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Numbers

    func testOneNumberKeyForEveryWayOfWritingIt() {
        let key = ChatHandle.key("+31 6 1234 5678")
        XCTAssertEqual(key, "612345678")
        XCTAssertEqual(ChatHandle.key("0612345678"), key)
        XCTAssertEqual(ChatHandle.key("31612345678@s.whatsapp.net"), key)
        XCTAssertEqual(ChatHandle.key("31612345678:3@s.whatsapp.net"), key, "a device suffix is no part of the number")
        XCTAssertEqual(ChatHandle.key("Lisa@Example.com"), "lisa@example.com")
        XCTAssertEqual(ChatHandle.key("٠٦١٢٣٤٥٦٧٨"), key, "digits in another script are the same digits")
        XCTAssertNil(ChatHandle.key(""))
        XCTAssertEqual(AppData.key("+31 6 1234 5678"), key, "AppData's key is the shared one")
    }

    func testOneMinimumLengthForANumber() {
        XCTAssertEqual(ChatHandle.digitCount.lowerBound, 6)
        XCTAssertEqual(ChatHandle.phoneKey("123456"), "123456", "six digits are a short local number")
        XCTAssertNil(ChatHandle.phoneKey("12345"), "five are a code, never a person")
        XCTAssertEqual(AppData.key("12345"), "", "too short for a key")
        XCTAssertEqual(ChatMentions.key("+31 6 1234 5678"), "612345678")
        XCTAssertNil(ChatMentions.key("12345"))
        XCTAssertEqual(ChatHandle.e164("123456"), "+123456")
        XCTAssertNil(ChatHandle.e164("12345"))
        XCTAssertNil(ChatHandle.e164("1234567890123456"), "E.164 has fifteen digits at most")
        XCTAssertEqual(ChatCalls.phoneDigits("0031 6 12345678"), "+31612345678")
        XCTAssertTrue(ChatContactCard(name: "Anna", phone: "123 456").isValid)
        XCTAssertFalse(ChatContactCard(name: "Anna", phone: "12345").isValid)
        XCTAssertTrue(ChatHandle.looksLikeNumber("06 1234 5678"))
        XCTAssertFalse(ChatHandle.looksLikeNumber("Anna 2"))
    }

    func testOneFoldForNames() {
        XCTAssertEqual(ChatText.fold("  Zoë "), "zoe")
        XCTAssertEqual(ChatText.fold("Ｊｏｓé"), "jose", "width and accents both go")
        XCTAssertEqual(ChatText.words("Anna-Marie  (Work)"), "anna marie work")
        XCTAssertEqual(ChatPeople.fold("Anna-Marie"), ChatText.words("Anna-Marie"))
    }

    // MARK: Identity

    private func thread(_ app: String, _ name: String, handle: String? = nil, phone: String? = nil, email: String? = nil) -> InboxThread {
        var thread = InboxThread(id: app + "|" + name, app: app, name: name, messages: [
            InboxMessage(id: "m", text: "hello", date: now),
        ])
        thread.kind = .person
        thread.handle = handle
        if phone != nil || email != nil { thread.profile = ChatProfile(phone: phone, email: email) }
        return thread
    }

    func testIdentityComesFromWhatEachAppSays() {
        XCTAssertEqual(thread("whatsapp", "Anna", handle: "31612345678@s.whatsapp.net").identity, "tel:612345678")
        XCTAssertEqual(thread("telegram", "Anna", phone: "+31 6 12345678").identity, "tel:612345678", "Telegram's profile number")
        XCTAssertEqual(thread("slack", "Anna", email: "Anna@Contoso.com").identity, "mail:anna@contoso.com")
        XCTAssertEqual(thread("messages", "Anna", handle: "anna@icloud.com").identity, "mail:anna@icloud.com")
        XCTAssertEqual(thread("signal", "Anna-Marie").identity, "name:anna marie")
        XCTAssertEqual(thread("teams", "Anna", email: "anna@contoso.com").contactHandle, "anna@contoso.com")
    }

    func testPeopleJoinTheSamePersonByNumberAndAddressAcrossApps() {
        let people = ChatPeople.people([
            thread("whatsapp", "Anna de Vries", handle: "+31 6 1234 5678"),
            thread("telegram", "Anna", phone: "0612345678"),
            thread("slack", "Anna V.", email: "anna@contoso.com"),
            thread("teams", "Anna de Vries (Contoso)", email: "ANNA@contoso.com"),
            thread("signal", "Bob"),
        ])
        XCTAssertEqual(people.count, 3)
        XCTAssertEqual(people.first { $0.id == "tel:612345678" }?.apps.sorted(), ["telegram", "whatsapp"])
        XCTAssertEqual(people.first { $0.id == "mail:anna@contoso.com" }?.apps.sorted(), ["slack", "teams"])
    }

    func testABridgeWithoutAHandleGetsTheOneItsProfileSays() {
        var inbox = ChatInbox()
        var chat = BridgedChat(app: "telegram", name: "Anna", messages: [InboxMessage(id: "1", text: "hi", date: now)], unread: 1)
        chat.kind = .person
        chat.profile = ChatProfile(phone: "+31612345678")
        XCTAssertTrue(inbox.merge([chat], now: now))
        XCTAssertEqual(inbox.threads.values.first?.handle, "+31612345678", "Contacts finds the person by it")
        var group = BridgedChat(app: "telegram", name: "Team", messages: [InboxMessage(id: "2", text: "hi", date: now)], unread: 1)
        group.kind = .group
        group.profile = ChatProfile(phone: "+31600000000")
        inbox.merge([group], now: now)
        XCTAssertNil(inbox.threads[ChatInbox.key(app: "telegram", chat: "Team")]?.handle, "a group is no person")
    }

    // MARK: Which chat

    private func inbox(_ threads: [InboxThread]) -> ChatInbox {
        var inbox = ChatInbox()
        for thread in threads { inbox.threads[thread.id] = thread }
        return inbox
    }

    func testANameThatFitsTwoChatsIsNeverAGuess() {
        let inbox = inbox([thread("whatsapp", "Anna de Vries"), thread("telegram", "Anna Bakker"), thread("signal", "Bob")])
        guard case .several(let both) = inbox.pick("Anna") else { return XCTFail("two Annas: ask which") }
        XCTAssertEqual(Set(both.map(\.app)), ["whatsapp", "telegram"])
        XCTAssertNil(inbox.thread(named: "Anna"))
        XCTAssertEqual(inbox.thread(named: "Anna", app: "telegram")?.name, "Anna Bakker", "the app tells them apart")
        XCTAssertEqual(inbox.thread(named: "anna de vries")?.app, "whatsapp")
        XCTAssertEqual(inbox.thread(named: "Bakker")?.app, "telegram", "a whole word")
        XCTAssertEqual(inbox.thread(named: "Ana de Vries")?.app, "whatsapp", "a typo")
        XCTAssertTrue(ChatInbox.which("Anna", among: both).contains("WhatsApp"))
        if case .none = inbox.pick("Zed") {} else { XCTFail("nobody is called Zed") }
    }

    func testAChatIsFoundByItsNumberOrIdInEveryApp() {
        let anna = thread("telegram", "Anna", phone: "+31 6 1234 5678")
        let inbox = inbox([anna, thread("signal", "Bob", phone: "+31 6 0000 0000")])
        XCTAssertEqual(inbox.thread(named: "0612345678")?.name, "Anna")
        XCTAssertNil(inbox.thread(named: "0699999999"), "a number nobody has finds no one, not a name")
        XCTAssertEqual(inbox.thread(named: anna.id)?.name, "Anna")
    }
}
