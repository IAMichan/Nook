import XCTest

final class TeamsWebDataTests: XCTestCase {
    private let me = "8:orgid:me"

    /// A token as the Teams website sends it: only its claims matter here.
    private func token(_ claims: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJSUzI1NiJ9." + payload + ".sig"
    }

    func testTheSessionComesFromAChatServiceRequest() {
        let jwt = token(["skypeid": "orgid:me", "exp": 1_900_000_000])
        let url = "https://teams.microsoft.com/api/chatsvc/emea/v1/users/ME/conversations?view=msnp24Equivalent"
        let session = TeamsWebData.session(url: url, header: "skypetoken=" + jwt)
        XCTAssertEqual(session?.base, "https://teams.microsoft.com/api/chatsvc/emea")
        XCTAssertEqual(session?.me, me)
        XCTAssertEqual(session?.token, jwt)
        XCTAssertEqual(session?.expires, Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertNil(TeamsWebData.session(url: "https://teams.microsoft.com/api/mt/emea/beta/users", header: "skypetoken=" + jwt),
                     "only the chat service's requests count")
        XCTAssertNil(TeamsWebData.session(url: url, header: "skypetoken=" + token(["exp": 1])), "a token that says who you are")
    }

    func testChatsAndMessages() {
        let list: [String: Any] = ["conversations": [
            ["id": "19:a_b@unq.gbl.spaces", "threadProperties": [:], "properties": ["consumptionhorizon": "1700000000000;1;2"],
             "lastMessage": ["id": "1", "messagetype": "RichText/Html", "content": "<p>Hi&nbsp;there</p>", "imdisplayname": "Anna",
                             "from": "https://emea.ng.msg.teams.microsoft.com/v1/users/ME/contacts/8:orgid:anna",
                             "composetime": "2026-10-23T10:00:00.000Z"]],
            ["id": "19:group@thread.v2", "threadProperties": ["topic": "Launch"], "lastMessage": [:]],
            ["id": "19:meeting_x@thread.v2", "threadProperties": [:], "lastMessage": [:]],
            ["id": "19:channel@thread.tacv2", "threadProperties": ["topic": "General"]],
            ["id": "48:notifications", "threadProperties": [:]],
        ]]
        let chats = TeamsWebData.chats(list, me: me)
        XCTAssertEqual(chats.map(\.name), ["Anna", "Launch"], "no meeting chat without a topic, no channel, no service list")
        XCTAssertEqual(chats.first?.preview?.text, "Hi there")
        XCTAssertEqual(chats.first?.readUntil, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertFalse(chats[0].isGroup)
        XCTAssertTrue(chats[1].isGroup)

        let history: [String: Any] = ["messages": [
            ["id": "3", "messagetype": "Text", "content": "Mine", "imdisplayname": "Me Myself",
             "from": "https://x/contacts/" + me, "composetime": "2026-10-23T10:02:00.000Z"],
            ["id": "2", "messagetype": "ThreadActivity/AddMember", "content": "", "composetime": "2026-10-23T10:01:00.000Z"],
            ["id": "1", "messagetype": "RichText/Html", "content": "", "imdisplayname": "Bo", "from": "https://x/contacts/8:orgid:bo",
             "properties": ["files": "[{\"fileName\":\"plan.pdf\"}]"], "composetime": "2026-10-23T10:00:00.000Z"],
            ["id": "0", "messagetype": "Text", "content": "gone", "from": "https://x/contacts/8:orgid:bo",
             "properties": ["deletetime": 1], "composetime": "2026-10-23T09:00:00.000Z"],
        ]]
        let messages = TeamsWebData.messages(history, chat: chats[1], me: me)
        XCTAssertEqual(messages.map(\.text), ["plan.pdf", "Mine"], "oldest first; no activity, no deleted message")
        XCTAssertEqual(messages.first?.sender, "Bo")
        XCTAssertEqual(messages.last?.isMine, true)
        XCTAssertEqual(TeamsWebData.people(history, me: me), ["Bo"])
        XCTAssertEqual(TeamsWebData.myName(history, me: me), "Me Myself")
        XCTAssertTrue(TeamsWebData.caughtUp(history, last: ChatJSON.date("2026-10-23T10:02:00.000Z")))
        XCTAssertFalse(TeamsWebData.caughtUp(history, last: ChatJSON.date("2026-10-23T11:00:00.000Z")))
    }
}
