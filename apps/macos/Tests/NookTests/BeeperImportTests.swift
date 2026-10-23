import XCTest

/// Moving from Beeper: which accounts and chat settings come over from Beeper Desktop's API, and what is still to be
/// done in a chat once its app is linked in Nook.
final class BeeperImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAccountsGoToTheirApps() {
        let listed: [[String: Any]] = [
            ["accountID": "instagramgo", "network": "Instagram", "user": ["username": "anna.ig"]],
            ["accountID": "local-telegram_1", "network": "Telegram", "user": ["fullName": " ", "phoneNumber": "+316"]],
            ["accountID": "hungryserv", "network": "Beeper", "user": ["fullName": "Anna"]],
            ["accountID": "gmessages", "network": "Google Messages", "user": ["fullName": "Anna"]],
            ["accountID": "instagramgo", "network": "Instagram", "user": ["username": "anna.ig"]],
            ["accountID": "", "network": "Signal"],
        ]
        let accounts = BeeperImport.accounts(listed)
        XCTAssertEqual(accounts.map(\.app), ["instagram", "telegram"], "Beeper's own network, unknown ones and repeats left out")
        XCTAssertEqual(accounts.map(\.name), ["anna.ig", "+316"], "the first name there is")
        let wrapped: [String: Any] = ["items": [["accountID": "signal", "network": "Signal"]]]
        XCTAssertEqual(BeeperImport.accounts(wrapped).map(\.app), ["signal"])
        XCTAssertEqual(BeeperImport.accounts(nil), [])
    }

    func testAppsOnceEach() {
        let accounts = [BeeperImport.Account(id: "a", app: "signal", name: "Anna"),
                        BeeperImport.Account(id: "b", app: "x", name: "anna"),
                        BeeperImport.Account(id: "c", app: "signal", name: "Werk")]
        XCTAssertEqual(BeeperImport.apps(accounts), ["signal", "x"])
    }

    func testChatSettings() {
        let settings = BeeperImport.settings(["items": [
            ["id": "!a", "accountID": "instagramgo", "network": "Instagram", "title": "Anna", "isPinned": true],
            ["id": "!b", "accountID": "signal", "network": "Signal", "title": "Club", "isMuted": true, "isArchived": true],
            ["id": "!c", "accountID": "signal", "network": "Signal", "title": "Jan"],
            ["id": "!d", "accountID": "whatsapp", "network": "WhatsApp", "title": "Familie", "isPinned": true],
            ["id": "!e", "accountID": "signal", "network": "Signal", "title": "Alles", "isPinned": true, "merge": [:]],
            ["id": "!f", "accountID": "signal", "network": "Signal", "title": " ", "isPinned": true],
        ]], now: now)
        XCTAssertEqual(settings.map(\.key), [ChatInbox.key(app: "instagram", chat: "Anna"), ChatInbox.key(app: "signal", chat: "Club")],
                       "only set chats with a name; WhatsApp's and merged ones are left out")
        XCTAssertTrue(settings[0].pinned)
        XCTAssertTrue(settings[1].muted && settings[1].archived)
        XCTAssertFalse(settings[1].pinned)
    }

    func testSettingsWaitThenGo() {
        let old = BeeperImport.ChatSetting(app: "signal", name: "Club", pinned: true, since: now)
        let newer = BeeperImport.ChatSetting(app: "signal", name: "Club", muted: true, since: now.addingTimeInterval(60))
        let other = BeeperImport.ChatSetting(app: "x", name: "Jan", pinned: true, since: now)
        let merged = BeeperImport.merged([old, other], [newer], now: now.addingTimeInterval(120))
        XCTAssertEqual(merged, [newer, other].sorted { $0.key < $1.key }, "a newer setting for a chat replaces the older")
        XCTAssertEqual(BeeperImport.merged(merged, [], now: now.addingTimeInterval(60 + BeeperImport.settingsKeep + 1)), [],
                       "settings whose chat never shows up are let go")
    }

    func testOnlyWhatIsNotDoneYetChanges() {
        let setting = BeeperImport.ChatSetting(app: "signal", name: "Club", pinned: true, muted: true, since: now)
        var chat = ChatServiceData.Chat(id: "!b", app: "signal", title: "Club", isGroup: true, unread: 0, last: nil)
        XCTAssertEqual(BeeperImport.change(setting, for: chat), BeeperImport.Change(pin: true, mute: true))
        chat.isPinned = true
        chat.isMuted = true
        XCTAssertTrue(BeeperImport.change(setting, for: chat).isEmpty)
        let archived = BeeperImport.ChatSetting(app: "signal", name: "Club", archived: true, since: now)
        XCTAssertEqual(BeeperImport.change(archived, for: chat), BeeperImport.Change(archive: true))
    }

    func testHistoryKeepsTextOnly() {
        let messages = [
            InboxMessage(id: "1", text: "hoi", date: now),
            InboxMessage(id: "2", text: "", date: now, media: ChatMedia(kind: .photo)),
            InboxMessage(id: "3", text: "kijk", date: now, media: ChatMedia(kind: .photo)),
            InboxMessage(id: "4", text: "", date: now),
        ]
        XCTAssertEqual(BeeperImport.history(messages).map(\.id), ["1"], "files stay in Beeper's folder")
    }
}
