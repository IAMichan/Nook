import XCTest

/// Instagram read the way Beeper reads it: what its web API answers about your threads, turned into chats, and what Nook
/// sends back.
final class InstagramDataTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private let inbox = """
    {"viewer": {"pk": 100, "username": "me"},
     "inbox": {"threads": [
       {"thread_id": "340282366841710300949128", "thread_title": "Anna", "is_group": false,
        "users": [{"pk": 200, "username": "anna.b", "full_name": "Anna"}],
        "last_activity_at": "1761124496000000", "read_state": 1,
        "last_seen_at": {"100": {"timestamp": "1761124400000000", "item_id": "1"}},
        "items": [
          {"item_id": "3", "user_id": 200, "timestamp": "1761124496000000", "item_type": "text", "text": "See you at 8?"},
          {"item_id": "2", "user_id": 100, "timestamp": "1761124450000000", "item_type": "text", "text": "Dinner tonight?"},
          {"item_id": "1", "user_id": 200, "timestamp": 1761124300000000, "item_type": "media", "media": {"media_type": 1}}
        ]},
       {"thread_id": "999", "thread_title": "", "is_group": true,
        "users": [{"pk": 300, "username": "bob", "full_name": ""}, {"pk": 400, "username": "cleo", "full_name": "Cleo"}],
        "last_activity_at": 1761120000000000, "read_state": 0,
        "items": [
          {"item_id": "9", "user_id": 400, "timestamp": 1761120000000000, "item_type": "link", "link": {"text": "look https://x.y"}},
          {"item_id": "8", "user_id": 300, "timestamp": 1761119000000000, "item_type": "action_log", "action_log": {"description": "bob joined"}}
        ]}
     ]},
     "status": "ok"}
    """

    func testThreadsBecomeChats() {
        let threads = InstagramData.threads(json(inbox))
        XCTAssertEqual(threads.map(\.name), ["Anna", "bob, Cleo"])

        let anna = threads[0]
        XCTAssertEqual(anna.id, "340282366841710300949128")
        XCTAssertFalse(anna.isGroup)
        XCTAssertEqual(anna.members, [])
        XCTAssertEqual(anna.last, Date(timeIntervalSince1970: 1_761_124_496))
        // Oldest first; your own message is yours, a private chat names no sender.
        XCTAssertEqual(anna.messages.map(\.id), ["instagram-1", "instagram-2", "instagram-3"])
        XCTAssertEqual(anna.messages[0].media?.kind, .photo)
        XCTAssertTrue(anna.messages[1].isMine)
        XCTAssertEqual(anna.messages[1].receipt, .sent)
        XCTAssertEqual(anna.messages[2].sender, "")
        // Only "See you at 8?" came after you last saw it.
        XCTAssertEqual(anna.unread, 1)

        let group = threads[1]
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.members, ["bob", "Cleo"])
        // The notice that someone joined is no message; a group names who wrote.
        XCTAssertEqual(group.messages.map(\.text), ["look https://x.y"])
        XCTAssertEqual(group.messages[0].sender, "Cleo")
        XCTAssertEqual(group.unread, 0)
    }

    func testAThreadMarkedUnreadCountsAtLeastOne() {
        let thread = InstagramData.thread(json("""
        {"thread_id": "1", "thread_title": "Jan", "viewer_id": "100", "read_state": 1,
         "users": [{"pk": "200", "username": "jan"}], "items": []}
        """), me: nil)
        XCTAssertEqual(thread?.name, "Jan")
        XCTAssertEqual(thread?.unread, 1)
    }

    func testAThreadWithoutAnyNameIsLeftOut() {
        XCTAssertNil(InstagramData.thread(json(#"{"thread_id": "1", "users": []}"#), me: "100"))
        XCTAssertNil(InstagramData.thread(json(#"{"thread_title": "No id"}"#), me: "100"))
    }

    func testOnlyInstagramsOwnSessionCookieCounts() {
        XCTAssertTrue(InstagramData.isSession(name: "sessionid", domain: ".instagram.com", value: "abc"))
        XCTAssertTrue(InstagramData.isSession(name: "sessionid", domain: "www.instagram.com", value: "abc"))
        XCTAssertFalse(InstagramData.isSession(name: "sessionid", domain: ".instagram.com", value: ""))
        XCTAssertFalse(InstagramData.isSession(name: "sessionid", domain: "notinstagram.com", value: "abc"))
        XCTAssertFalse(InstagramData.isSession(name: "csrftoken", domain: ".instagram.com", value: "abc"))
    }

    func testAnswers() throws {
        XCTAssertEqual(try InstagramData.check(status: 200, url: "https://www.instagram.com/api/v1/direct_v2/inbox/",
                                               body: #"{"status": "ok"}"#)["status"] as? String, "ok")
        for (status, url, body) in [(200, "https://www.instagram.com/accounts/login/?next=/api", "<html>"),
                                    (401, "https://www.instagram.com/api", "<html>"),
                                    (403, "https://www.instagram.com/api", #"{"message": "login_required", "status": "fail"}"#)] {
            XCTAssertThrowsError(try InstagramData.check(status: status, url: url, body: body)) { error in
                XCTAssertEqual((error as? NookError)?.kind, .auth)
                XCTAssertEqual((error as? NookError)?.message, tr("chats.instagram.signedOut"))
            }
        }
        XCTAssertThrowsError(try InstagramData.check(status: 400, url: "", body: #"{"message": "checkpoint_required", "status": "fail"}"#)) {
            XCTAssertEqual(($0 as? NookError)?.message, tr("chats.instagram.checkpoint"))
        }
        XCTAssertThrowsError(try InstagramData.check(status: 429, url: "", body: "")) {
            XCTAssertEqual(($0 as? NookError)?.kind, .rateLimited)
        }
        XCTAssertThrowsError(try InstagramData.check(status: 200, url: "", body: #"{"message": "Thread not found", "status": "fail"}"#)) {
            XCTAssertEqual(($0 as? NookError)?.message, tr("chats.instagram.refused", "Thread not found"))
        }
    }

    func testTheSendForm() {
        let form = InstagramData.sendForm(thread: "340282", text: "Hi & bye", context: "6123")
        XCTAssertEqual(form["thread_ids"], #"["340282"]"#)
        XCTAssertEqual(form["text"], "Hi & bye")
        XCTAssertEqual(form["action"], "send_item")
        XCTAssertEqual(form["client_context"], "6123")
        XCTAssertTrue(InstagramData.form(form).contains("text=Hi%20%26%20bye"))
        XCTAssertEqual(InstagramData.newContext().count, 19)
    }
}
