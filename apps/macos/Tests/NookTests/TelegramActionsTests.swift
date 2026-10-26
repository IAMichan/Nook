import XCTest

/// Telegram's chat actions as TDLib takes them (pin, mute, archive, edit, delete), and the pinned and muted state and
/// deletions TDLib reports.
final class TelegramActionsTests: XCTestCase {
    private func listType(_ value: Any?) -> String? {
        (value as? [String: Any])?["@type"] as? String
    }

    // MARK: State

    func testChatReadsPinnedAndMuted() {
        let chat = TelegramData.chat([
            "@type": "chat", "id": 7, "title": "Anna", "type": ["@type": "chatTypePrivate", "user_id": 7],
            "positions": [
                ["@type": "chatPosition", "list": ["@type": "chatListArchive"], "order": "1", "is_pinned": false],
                ["@type": "chatPosition", "list": ["@type": "chatListMain"], "order": "99", "is_pinned": true],
            ],
            "notification_settings": ["@type": "chatNotificationSettings", "use_default_mute_for": false, "mute_for": 3600],
        ])
        XCTAssertEqual(chat?.isPinned, true)
        XCTAssertEqual(chat?.isMuted, true)
        XCTAssertEqual(chat?.order, 99)
    }

    func testChatWithoutPositionsOrSettingsIsNeitherPinnedNorMuted() {
        let chat = TelegramData.chat(["@type": "chat", "id": 7, "title": "Anna", "type": ["@type": "chatTypePrivate"]])
        XCTAssertEqual(chat?.isPinned, false)
        XCTAssertEqual(chat?.isMuted, false)
    }

    func testPinnedOnlyCountsInTheMainList() {
        XCTAssertFalse(TelegramData.isPinned([["list": ["@type": "chatListArchive"], "is_pinned": true]] as [[String: Any]]))
        XCTAssertTrue(TelegramData.isPinned([["list": ["@type": "chatListMain"], "is_pinned": true]] as [[String: Any]]))
        XCTAssertFalse(TelegramData.isPinned(nil))
    }

    func testMutedFollowsMuteFor() {
        XCTAssertTrue(TelegramData.isMuted(["mute_for": TelegramData.muteForever] as [String: Any]))
        XCTAssertFalse(TelegramData.isMuted(["mute_for": 0] as [String: Any]))
        XCTAssertFalse(TelegramData.isMuted(nil))
    }

    func testMainPositionUpdate() {
        let pinned = TelegramData.mainPosition([
            "@type": "updateChatPosition", "chat_id": -100123,
            "position": ["@type": "chatPosition", "list": ["@type": "chatListMain"], "order": "500", "is_pinned": true],
        ])
        XCTAssertEqual(pinned?.chat, -100123)
        XCTAssertEqual(pinned?.order, 500)
        XCTAssertEqual(pinned?.pinned, true)

        let left = TelegramData.mainPosition([
            "@type": "updateChatPosition", "chat_id": 5,
            "position": ["@type": "chatPosition", "list": ["@type": "chatListMain"], "order": "0", "is_pinned": true],
        ])
        XCTAssertEqual(left?.order, 0)
        XCTAssertEqual(left?.pinned, false, "a chat that left the main list is not pinned there")

        XCTAssertNil(TelegramData.mainPosition([
            "@type": "updateChatPosition", "chat_id": 5,
            "position": ["@type": "chatPosition", "list": ["@type": "chatListArchive"], "order": "3"],
        ]), "a place in the archive leaves the main list as it is")
    }

    func testDeletedMessagesOnlyWhenPermanent() {
        let gone = TelegramData.deletedMessages(["@type": "updateDeleteMessages", "chat_id": -5, "message_ids": [10, 11],
                                                 "is_permanent": true, "from_cache": false])
        XCTAssertEqual(gone?.chat, -5)
        XCTAssertEqual(gone?.messages, [10, 11])
        XCTAssertNil(TelegramData.deletedMessages(["@type": "updateDeleteMessages", "chat_id": -5, "message_ids": [10],
                                                   "is_permanent": false, "from_cache": true]))
        XCTAssertNil(TelegramData.deletedMessages(["@type": "updateDeleteMessages", "chat_id": -5, "message_ids": [Int](),
                                                   "is_permanent": true]))
    }

    // MARK: Requests

    func testTogglePinned() {
        let request = TelegramData.togglePinned(true, chat: -100123)
        XCTAssertEqual(request["@type"] as? String, "toggleChatIsPinned")
        XCTAssertEqual(listType(request["chat_list"]), "chatListMain")
        XCTAssertEqual(request["chat_id"] as? Int64, -100123)
        XCTAssertEqual(request["is_pinned"] as? Bool, true)
        XCTAssertEqual(TelegramData.togglePinned(false, chat: 1)["is_pinned"] as? Bool, false)
    }

    func testSetMutedKeepsOtherSettings() {
        let current: [String: Any] = ["@type": "chatNotificationSettings", "use_default_mute_for": true, "mute_for": 0,
                                      "use_default_sound": false, "sound_id": "42", "show_preview": false]
        let request = TelegramData.setMuted(true, chat: 7, current: current)
        XCTAssertEqual(request["@type"] as? String, "setChatNotificationSettings")
        XCTAssertEqual(request["chat_id"] as? Int64, 7)
        let settings = request["notification_settings"] as? [String: Any] ?? [:]
        XCTAssertEqual(settings["@type"] as? String, "chatNotificationSettings")
        XCTAssertEqual(settings["use_default_mute_for"] as? Bool, false)
        XCTAssertEqual(settings["mute_for"] as? Int, TelegramData.muteForever)
        XCTAssertEqual(settings["use_default_sound"] as? Bool, false)
        XCTAssertEqual(settings["sound_id"] as? String, "42")
        XCTAssertEqual(settings["show_preview"] as? Bool, false)
    }

    func testUnmuteWithoutKnownSettingsUsesDefaults() {
        let settings = TelegramData.setMuted(false, chat: 7)["notification_settings"] as? [String: Any] ?? [:]
        XCTAssertEqual(settings["use_default_mute_for"] as? Bool, false)
        XCTAssertEqual(settings["mute_for"] as? Int, 0)
        XCTAssertEqual(settings["use_default_sound"] as? Bool, true)
        XCTAssertEqual(settings["use_default_show_preview"] as? Bool, true)
        XCTAssertTrue(TelegramData.isMuted(TelegramData.setMuted(true, chat: 7)["notification_settings"]))
    }

    func testArchive() {
        let request = TelegramData.archive(chat: 9)
        XCTAssertEqual(request["@type"] as? String, "addChatToList")
        XCTAssertEqual(request["chat_id"] as? Int64, 9)
        XCTAssertEqual(listType(request["chat_list"]), "chatListArchive")
    }

    func testEditMessageText() {
        let request = TelegramData.editMessageText(chat: -100123, message: 45, text: "Fixed typo")
        XCTAssertEqual(request["@type"] as? String, "editMessageText")
        XCTAssertEqual(request["chat_id"] as? Int64, -100123)
        XCTAssertEqual(request["message_id"] as? Int64, 45)
        let content = request["input_message_content"] as? [String: Any] ?? [:]
        XCTAssertEqual(content["@type"] as? String, "inputMessageText")
        let text = content["text"] as? [String: Any] ?? [:]
        XCTAssertEqual(text["@type"] as? String, "formattedText")
        XCTAssertEqual(text["text"] as? String, "Fixed typo")
    }

    func testDeleteMessagesForEveryone() {
        let request = TelegramData.deleteMessages(chat: -5, messages: [45])
        XCTAssertEqual(request["@type"] as? String, "deleteMessages")
        XCTAssertEqual(request["chat_id"] as? Int64, -5)
        XCTAssertEqual(request["message_ids"] as? [Int64], [45])
        XCTAssertEqual(request["revoke"] as? Bool, true)
    }

    func testRequestsFromNookMessageIDs() throws {
        let ids = try XCTUnwrap(TelegramData.ids("telegram--100123-45"))
        let request = TelegramData.deleteMessages(chat: ids.chat, messages: [ids.message])
        XCTAssertNotNil(TelegramData.request(request), "the request turns into JSON for TDLib")
        XCTAssertEqual(request["chat_id"] as? Int64, -100123)
    }
}
