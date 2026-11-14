import XCTest

final class ChatStoreTests: XCTestCase {
    private var folder: URL!
    private var store: ChatStore!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("chat-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = try XCTUnwrap(ChatStore(url: folder.appendingPathComponent("chats.sqlite")))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)

    private func message(_ index: Int, _ text: String? = nil, sender: String = "Anna") -> InboxMessage {
        InboxMessage(id: "m\(index)", sender: sender, text: text ?? "bericht \(index)", date: start.addingTimeInterval(Double(index) * 60))
    }

    private func thread(_ key: String = "telegram|familie", messages: [InboxMessage]) -> InboxThread {
        var thread = InboxThread(id: key, app: "telegram", name: "Familie")
        thread.messages = messages
        thread.bridged = true
        thread.unread = 2
        return thread
    }

    private func inbox(_ threads: InboxThread...) -> ChatInbox {
        var inbox = ChatInbox()
        inbox.lastRecord = 42
        for thread in threads { inbox.threads[thread.id] = thread }
        return inbox
    }

    // MARK: What is kept

    func testEveryFieldOfAMessageIsAColumnOrExtra() {
        let columns: Set<String> = ["id", "sender", "text", "date", "fromMe"]
        let extra = Set(Mirror(reflecting: ChatStore.Extra(message(0))).children.compactMap(\.label))
        let fields = Set(Mirror(reflecting: message(0)).children.compactMap(\.label))
        XCTAssertEqual(fields, columns.union(extra), "a new field of InboxMessage must be kept by ChatStore")
    }

    func testAMessageComesBackExactlyAsItWas() throws {
        var full = message(1, "Héél goed 👍")
        full.fromMe = false
        full.senderID = "123"
        full.edited = true
        full.mentionsMe = true
        full.importance = .urgent
        full.receipt = .read
        full.reactions = [InboxReaction(emoji: "❤️", count: 2, mine: true, people: ["Bram"])]
        full.quote = InboxQuote(id: "m0", sender: "Bram", text: "hoi", mine: false)
        var mine = message(2, "")
        mine.fromMe = true
        mine.sender = ""
        let chat = thread(messages: [full, mine])

        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let loaded = try XCTUnwrap(store.loadInbox(window: 50))
        XCTAssertEqual(loaded.inbox.threads[chat.id], chat)
        XCTAssertEqual(loaded.inbox.lastRecord, 42)
        XCTAssertEqual(loaded.oldest[chat.id], full.date)
    }

    // MARK: Paging

    func testLaunchHoldsTheWindowAndScrollingBackReadsTheRest() throws {
        let all = (0..<120).map { message($0) }
        var chat = thread(messages: all)
        chat.capacity = 120
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))

        let loaded = try XCTUnwrap(store.loadInbox(window: 50))
        let shown = try XCTUnwrap(loaded.inbox.threads[chat.id])
        XCTAssertEqual(shown.messages.map(\.id), all.suffix(50).map(\.id))
        XCTAssertNil(shown.capacity, "the rest is in the archive, not in memory")

        let first = try XCTUnwrap(shown.messages.first)
        let page = store.older(chat.id, before: first.date, excluding: Set(shown.messages.map(\.id)), limit: 50)
        XCTAssertEqual(page.map(\.id), all[20..<70].map(\.id))
        let last = store.older(chat.id, before: page[0].date, excluding: [page[0].id], limit: 50)
        XCTAssertEqual(last.map(\.id), all[0..<20].map(\.id))
        XCTAssertEqual(store.oldest(chat.id)?.id, "m0")
    }

    func testMessagesWithOneDateAreAllPagedThrough() {
        let same = (0..<5).map { InboxMessage(id: "s\($0)", text: "x", date: start) }
        XCTAssertTrue(store.apply(from: nil, to: inbox(thread(messages: same))))
        let page = store.older("telegram|familie", before: start, excluding: ["s4"], limit: 10)
        XCTAssertEqual(Set(page.map(\.id)), ["s0", "s1", "s2", "s3"])
    }

    func testMessagesOfOneSecondKeepTheirOrderWhateverTheirIDs() throws {
        // Ids from a hash: whichever slot each gets, the order is the order of their dates.
        let close = (0..<12).map { InboxMessage(id: "q\($0)", text: "x", date: start.addingTimeInterval(Double($0) * 0.01)) }
        XCTAssertTrue(store.apply(from: nil, to: inbox(thread(messages: close))))
        let loaded = try XCTUnwrap(store.loadInbox(window: 50)?.inbox.threads["telegram|familie"])
        XCTAssertEqual(loaded.messages.map(\.id), close.map(\.id))
        XCTAssertEqual(store.older("telegram|familie", before: close[11].date, excluding: ["q11"], limit: 3).map(\.id),
                       ["q8", "q9", "q10"])
        XCTAssertEqual(store.oldest("telegram|familie")?.id, "q0")
    }

    // MARK: Saving what changed

    func testAMessageTrimmedOffTheWindowStaysEvenWhenItSharesTheNewFirstOnesDate() {
        // Two messages of one second; the window keeps only the second of them.
        let tied = [InboxMessage(id: "a", text: "eerste", date: start), InboxMessage(id: "b", text: "tweede", date: start)]
        let chat = thread(messages: tied + [message(1)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        var next = chat
        next.messages.removeFirst()
        XCTAssertTrue(store.apply(from: inbox(chat), to: inbox(next)))
        XCTAssertEqual(store.messageCount(chat.id), 3, "it was trimmed, not removed")
    }

    func testASaveFromNothingStillHidesAndRemovesChatsThatLeft() throws {
        let removed = thread("telegram|weg", messages: [message(1, "geheim")])
        let quiet = thread("telegram|stil", messages: [message(2)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(removed, quiet)))

        // The diff could not be written: everything is written again from nothing.
        var next = inbox(removed, quiet)
        next.remove(removed.id)
        next.threads[quiet.id] = nil
        XCTAssertTrue(store.apply(from: nil, to: next))

        let shown = try XCTUnwrap(store.loadInbox(window: 10)).inbox.threads
        XCTAssertNil(shown[removed.id])
        XCTAssertNil(shown[quiet.id])
        XCTAssertEqual(store.messageCount(removed.id), 0)
        XCTAssertEqual(store.messageCount(quiet.id), 1, "a quiet chat stays for search")
    }

    // MARK: Backfill

    func testLayingAPageBesideTheArchiveClosesAHoleAndNeverBringsARemovedChatBack() {
        let chat = thread(messages: [message(1), message(9)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let page = ChatReconcile.Page(messages: (1..<9).map { message($0) }, high: message(9).date)
        XCTAssertEqual(store.reconcile(page, key: chat.id), 7, "what Nook missed in between")
        XCTAssertEqual(store.reconcile(page, key: chat.id), 0, "a page it already gave is nothing new")
        XCTAssertEqual(store.older(chat.id, before: message(9).date, excluding: ["m9"], limit: 20).map(\.id), (1..<9).map { "m\($0)" })
        XCTAssertTrue(store.deleteChat(chat.id))
        XCTAssertNil(store.reconcile(page, key: chat.id))
        XCTAssertNil(store.thread(chat.id, window: 10), "the chat is not made again")
    }

    func testAPageBringsOldEditsAndWhatTheAppLeftOutIsDeletedKeepingItsText() throws {
        var mine = message(3, "van mij")
        mine.fromMe = true
        let chat = thread(messages: [message(1), message(2, "oud"), mine, message(4, "weg"), InboxMessage(id: "n77", text: "melding", date: message(5).date), message(6)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        var edited = message(2, "nieuw")
        edited.edited = true
        // Slack and Telegram leave a deleted message out; your own and a notification's copy are never taken for one.
        let page = ChatReconcile.Page(messages: [message(1), edited], high: message(6).date, omitsDeleted: true)
        XCTAssertEqual(store.reconcile(page, key: chat.id), 0)

        let all = store.between(chat.id, after: .distantPast, before: .distantFuture)
        XCTAssertEqual(all.first { $0.id == "m2" }?.text, "nieuw")
        XCTAssertEqual(store.versions("m2", inChat: chat.id).map(\.text), ["oud"])
        let gone = try XCTUnwrap(all.first { $0.id == "m4" })
        XCTAssertTrue(gone.isDeleted)
        XCTAssertEqual(gone.text, "weg", "someone else's deleted message keeps what it said")
        XCTAssertFalse(all.first { $0.id == "m3" }?.isDeleted ?? true)
        XCTAssertFalse(all.first { $0.id == "n77" }?.isDeleted ?? true)
        XCTAssertFalse(all.first { $0.id == "m6" }?.isDeleted ?? true, "the page's end is not in the stretch it covers")
    }

    func testAnAppThatSaysWhatItDeletedIsBelievedAndANotificationsCopyGoes() {
        let notice = InboxMessage(id: "n5", sender: "Anna", text: "hallo daar", date: message(2).date.addingTimeInterval(3))
        let chat = thread(messages: [message(1), notice, message(3)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let page = ChatReconcile.Page(messages: [message(1), message(2, "hallo daar")], deleted: ["m3"], high: message(4).date)
        XCTAssertEqual(store.reconcile(page, key: chat.id), 1)
        let all = store.between(chat.id, after: .distantPast, before: .distantFuture)
        XCTAssertEqual(all.map(\.id), ["m1", "m2", "m3"], "the notification's copy made way for the app's own")
        XCTAssertTrue(all.last?.isDeleted == true)
    }

    func testAnAppThatOnlyChangesWordsByEditingKeepsTheOldWordsToo() {
        let chat = thread(messages: [message(1, "eerst"), message(2)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        // WhatsApp on this Mac keeps the new words only, with nothing that says the message was edited.
        let page = ChatReconcile.Page(messages: [message(1, "daarna")], high: message(2).date, textChangeIsEdit: true)
        XCTAssertEqual(store.reconcile(page, key: chat.id), 0)
        XCTAssertEqual(store.versions("m1", inChat: chat.id).map(\.text), ["eerst"])
        XCTAssertEqual(store.between(chat.id, after: .distantPast, before: message(2).date).first?.isEdited, true)
    }

    func testAMailInTheTrashUnderANewIDMarksTheStoredOneDeletedKeepingItsText() throws {
        var sent = InboxMessage(id: "mail-10", text: "*Offerte*\nHierbij de offerte", date: message(1).date, fromMe: true)
        sent.receipt = .sent
        let other = InboxMessage(id: "mail-11", text: "*Vraag*\nHoe gaat het?", date: message(2).date, fromMe: false)
        let chat = thread("mail|werk~lisa@example.com", messages: [sent, other, message(3)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        // Mail moved it to the Trash and gave it a new id there: found by its side, time and subject.
        let trashed = InboxMessage(id: "mail-99", text: "*Offerte*", date: sent.date.addingTimeInterval(1), fromMe: true)
        let page = ChatReconcile.Page(messages: [], high: message(3).date, gone: [trashed])
        XCTAssertEqual(store.reconcile(page, key: chat.id), 0)
        let all = store.between(chat.id, after: .distantPast, before: .distantFuture)
        let gone = try XCTUnwrap(all.first { $0.id == "mail-10" })
        XCTAssertTrue(gone.isDeleted)
        XCTAssertEqual(gone.text, sent.text, "a mail you deleted keeps what it said")
        XCTAssertFalse(all.first { $0.id == "mail-11" }?.isDeleted ?? true)
        XCTAssertNil(all.first { $0.id == "mail-99" }, "the Trash's copy is not stored as a mail of its own")
    }

    func testAPageByCountMovesOnWhenTheArchiveCountIsOff() async throws {
        // The app holds 300 messages, a minute apart, oldest first; a page by offset counts from the newest.
        let all = (0..<300).map { message($0) }
        let fetch: (Int) async throws -> [InboxMessage] = { offset in
            let end = max(0, all.count - offset)
            return Array(all[max(0, end - 100)..<end])
        }
        let before = all[150].date
        for guess in [0, 150, 299, 500] {
            let page = try await ChatBackfill.page(before: before, guess: guess, limit: 100, fetch: fetch)
            XCTAssertTrue(page.contains { $0.id == "m149" }, "guess \(guess): the message right before the oldest is in it")
        }
    }

    func testAMessageWithNoFreeIDNearItsSecondIsStillSavedInItsPlace() throws {
        let chat = thread(messages: (0..<Int(ChatStore.maxSpill) + 20).map { InboxMessage(id: "f\($0)", text: "x", date: start) }
            + [message(1)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        XCTAssertEqual(store.messageCount(chat.id), chat.messages.count)
        XCTAssertEqual(store.loadInbox(window: 1)?.inbox.threads[chat.id]?.messages.map(\.id), ["m1"])
    }

    func testOnlyWhatChangedIsWrittenAndOlderMessagesStay() throws {
        let first = thread(messages: (0..<60).map { message($0) })
        let old = inbox(first)
        XCTAssertTrue(store.apply(from: nil, to: old))

        // The window moves on: the oldest leave memory, a new one arrives, one gets an emoji.
        var next = first
        next.messages = Array(first.messages.suffix(50))
        next.messages.append(message(60))
        next.messages[10].reactions = [InboxReaction(emoji: "👍", count: 1, mine: false)]
        XCTAssertTrue(store.apply(from: old, to: inbox(next)))

        XCTAssertEqual(store.messageCount(first.id), 61, "what left the window stays in the archive")
        let loaded = try XCTUnwrap(store.loadInbox(window: 100)?.inbox.threads[first.id])
        XCTAssertEqual(loaded.messages.count, 61)
        XCTAssertEqual(loaded.messages.first { $0.id == next.messages[10].id }?.reactions?.first?.emoji, "👍")
    }

    func testAMessageThatLeftFromWithinTheWindowGoes() {
        let chat = thread(messages: (0..<10).map { message($0) })
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        var next = chat
        next.messages.remove(at: 5)
        XCTAssertTrue(store.apply(from: inbox(chat), to: inbox(next)))
        XCTAssertEqual(store.messageCount(chat.id), 9)
    }

    func testARemovedChatGoesAndAQuietOneStaysForSearch() throws {
        let removed = thread("telegram|weg", messages: [message(1, "geheim")])
        let quiet = thread("telegram|stil", messages: [message(2, "voetbalploeg")])
        let old = inbox(removed, quiet)
        XCTAssertTrue(store.apply(from: nil, to: old))

        var next = old
        next.remove(removed.id)
        next.threads[quiet.id] = nil
        XCTAssertTrue(store.apply(from: old, to: next))

        XCTAssertEqual(store.messageCount(removed.id), 0)
        XCTAssertNil(store.thread(removed.id, window: 10))
        XCTAssertNil(store.loadInbox(window: 10)?.inbox.threads[quiet.id], "it no longer shows")
        XCTAssertEqual(store.thread(quiet.id, window: 10)?.messages.map(\.text), ["voetbalploeg"])
        XCTAssertEqual(store.search(["ploeg"], limit: 10).map(\.thread.id), [quiet.id])
    }

    func testAMessageThatMovedToItsGroupLeavesTheChatItCameFrom() {
        let person = thread("telegram|anna", messages: [message(1, "hoi")])
        let old = inbox(person)
        XCTAssertTrue(store.apply(from: nil, to: old))
        let group = thread("telegram|groep", messages: [message(1, "hoi")])
        XCTAssertTrue(store.apply(from: old, to: inbox(group)))
        XCTAssertEqual(store.messageCount(person.id), 0)
        XCTAssertEqual(store.messageCount(group.id), 1)
    }

    func testForgettingAChatsMessagesKeepsTheChat() {
        let chat = thread(messages: [message(1)])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        XCTAssertTrue(store.deleteChat(chat.id, keepChat: true))
        XCTAssertEqual(store.messageCount(chat.id), 0)
        XCTAssertNotNil(store.thread(chat.id, window: 10))
        XCTAssertTrue(store.search(["bericht"], limit: 10).isEmpty, "nothing of it is found any more")
    }

    // MARK: Edits and deletions of older messages

    func testAnEditOfAnOlderMessageKeepsWhatItSaidBefore() throws {
        let chat = thread(messages: [message(1, "eerste versie")])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let row = try XCTUnwrap(store.chatID(chat.id))

        XCTAssertTrue(store.edit("m1", chat: row, to: "tweede versie"))
        XCTAssertTrue(store.edit("m1", chat: row, to: "derde versie"))

        let now = try XCTUnwrap(store.stored("m1", chat: row)?.message)
        XCTAssertEqual(now.text, "derde versie")
        XCTAssertTrue(now.isEdited, "it says Edited")
        XCTAssertEqual(store.versions("m1", inChat: chat.id).map(\.text), ["eerste versie", "tweede versie"])
        XCTAssertEqual(store.search(["derde"], limit: 10).count, 1)
        XCTAssertTrue(store.search(["eerste"], limit: 10).isEmpty, "search finds what it says now")
    }

    func testSomeoneElsesDeletedMessageKeepsItsTextAndYoursDoesNot() throws {
        var mine = message(2, "van mij")
        mine.fromMe = true
        mine.sender = ""
        let chat = thread(messages: [message(1, "van Anna"), mine])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let row = try XCTUnwrap(store.chatID(chat.id))

        XCTAssertTrue(store.withdraw(["m1", "m2"], chat: row))

        let theirs = try XCTUnwrap(store.stored("m1", chat: row)?.message)
        XCTAssertTrue(theirs.isDeleted)
        XCTAssertEqual(theirs.text, "van Anna", "someone else's keeps what Nook had of it, marked Deleted")
        let yours = try XCTUnwrap(store.stored("m2", chat: row)?.message)
        XCTAssertTrue(yours.isDeleted)
        XCTAssertEqual(yours.text, "")
        XCTAssertTrue(store.versions("m2", inChat: chat.id).isEmpty, "nothing of your own deleted message is kept")
    }

    func testALaterReadNeverBringsADeletedMessageBack() throws {
        let chat = thread(messages: [message(1, "weg")])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let row = try XCTUnwrap(store.chatID(chat.id))
        XCTAssertTrue(store.withdraw(["m1"], chat: row))
        XCTAssertTrue(store.saveMerged(message(1, "weg"), chat: row))
        XCTAssertTrue(try XCTUnwrap(store.stored("m1", chat: row)).message.isDeleted)
    }

    func testAReadThatBringsLessKeepsWhatWasThere() throws {
        var full = message(1, "met tekst")
        full.reactions = [InboxReaction(emoji: "👍", count: 1, mine: false)]
        let chat = thread(messages: [full])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let row = try XCTUnwrap(store.chatID(chat.id))
        var preview = message(1, "")
        preview.reactions = nil
        XCTAssertTrue(store.saveMerged(preview, chat: row))
        let kept = try XCTUnwrap(store.stored("m1", chat: row)?.message)
        XCTAssertEqual(kept.text, "met tekst")
        XCTAssertEqual(kept.reactions?.first?.emoji, "👍")
    }

    func testAnEditInTheWindowKeepsTheOldTextToo() {
        let chat = thread(messages: [message(1, "oud")])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        var edited = chat
        edited.messages[0].text = "nieuw"
        edited.messages[0].edited = true
        XCTAssertTrue(store.apply(from: inbox(chat), to: inbox(edited)))
        XCTAssertEqual(store.versions("m1", inChat: chat.id).map(\.text), ["oud"])
    }

    func testRemovingAChatTakesItsEarlierVersionsAlong() throws {
        let chat = thread(messages: [message(1, "a")])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        XCTAssertTrue(store.edit("m1", chat: try XCTUnwrap(store.chatID(chat.id)), to: "b"))
        XCTAssertTrue(store.deleteChat(chat.id))
        XCTAssertTrue(store.versions("m1", inChat: chat.id).isEmpty)
        XCTAssertTrue(store.exec("SELECT 1"))
    }

    // MARK: Search

    func testSearchFindsPiecesOfWordsWithoutCaseOrAccents() throws {
        try XCTSkipUnless(store.searchAvailable, "this SQLite has no trigram tokenizer")
        let chat = thread(messages: [message(1, "Morgen naar het Café?"), message(2, "De voetbalploeg wint"),
                                     message(3, "niets", sender: "Bram Visser")])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        XCTAssertEqual(store.search(["cafe"], limit: 10).first?.messages.map(\.id), ["m1"])
        XCTAssertEqual(store.search(["ploeg"], limit: 10).first?.messages.map(\.id), ["m2"])
        XCTAssertEqual(store.search(["visser"], limit: 10).first?.messages.map(\.id), ["m3"], "the sender counts too")
        XCTAssertEqual(store.search(["de"], limit: 10).first?.messages.map(\.id), ["m2"], "a short word scans")
        XCTAssertEqual(store.search(["cafe", "ploeg"], limit: 10).first?.messages.map(\.id), ["m1", "m2"])
    }

    func testAnEditedMessageIsFoundByItsNewText() {
        let chat = thread(messages: [message(1, "oud woord")])
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        var edited = chat
        edited.messages[0].text = "nieuwe tekst"
        XCTAssertTrue(store.apply(from: inbox(chat), to: inbox(edited)))
        XCTAssertTrue(store.search(["woord"], limit: 10).isEmpty)
        XCTAssertEqual(store.search(["nieuwe"], limit: 10).count, 1)
    }

    func testSearchGivesTheNewestFirstUpToTheLimit() {
        let chat = thread(messages: (0..<30).map { message($0, "zelfde woord") })
        XCTAssertTrue(store.apply(from: nil, to: inbox(chat)))
        let found = store.search(["woord"], limit: 5).first?.messages.map(\.id)
        XCTAssertEqual(found, (25..<30).map { "m\($0)" })
    }

    // MARK: Size

    func testTheFileStaysSmallAndShrinksAfterDeleting() {
        let chats = (0..<20).map { chat in
            thread("telegram|chat\(chat)", messages: (0..<500).map { message($0, "Een gewoon chatbericht van een zin of zo, nummer \($0)") })
        }
        var all = ChatInbox()
        for chat in chats { all.threads[chat.id] = chat }
        XCTAssertTrue(store.apply(from: nil, to: all))
        let full = store.fileBytes
        // 10,000 messages of about 50 characters, with the paging and search indexes.
        XCTAssertLessThan(full, 4_000_000, "about 400 bytes per message at most")

        for chat in chats.prefix(15) { XCTAssertTrue(store.deleteChat(chat.id)) }
        store.maintain()
        XCTAssertLessThan(store.fileBytes, full / 2, "freed pages go back to the disk")
    }
}
