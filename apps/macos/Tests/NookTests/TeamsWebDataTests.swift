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

    func testTheSessionComesFromTheSignInService() {
        let skype = token(["skypeid": "orgid:me", "exp": 1_900_000_000])
        let answer: [String: Any] = ["tokens": ["skypeToken": skype, "expiresIn": 86_400], "region": "emea",
                                     "regionGtms": ["chatServiceAfd": "https://teams.microsoft.com/api/chatsvc/emea/"]]
        XCTAssertEqual(TeamsWebData.session(authz: answer)?.base, "https://teams.microsoft.com/api/chatsvc/emea")
        XCTAssertEqual(TeamsWebData.session(authz: answer)?.me, me)
        let regionOnly: [String: Any] = ["tokens": ["skypeToken": skype], "region": "amer"]
        XCTAssertEqual(TeamsWebData.session(authz: regionOnly)?.base, "https://teams.microsoft.com/api/chatsvc/amer")
        XCTAssertNil(TeamsWebData.session(authz: ["tokens": [:]]))
        let bearer = TeamsWebData.session(url: "https://teams.cloud.microsoft/api/chatsvc/emea/v1/users/ME", header: "Bearer " + skype)
        XCTAssertEqual(bearer?.token, skype, "the website may send the session token as a bearer")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let spaces = token(["aud": "https://api.spaces.skype.com", "exp": 1_900_000_000])
        XCTAssertTrue(TeamsWebData.isSpacesToken(spaces, now: now))
        XCTAssertFalse(TeamsWebData.isSpacesToken(token(["aud": "https://graph.microsoft.com", "exp": 1_900_000_000]), now: now))
        XCTAssertFalse(TeamsWebData.isSpacesToken(token(["aud": "https://api.spaces.skype.com", "exp": 1]), now: now), "run out")
        XCTAssertEqual(TeamsWebData.bearer(cookie: "Bearer%3D" + spaces + "%26Origin%3Dhttps%3A%2F%2Fteams.microsoft.com"), spaces)
        XCTAssertNil(TeamsWebData.bearer(cookie: "something-else"))
    }

    func testTheNewTeamsAsksTheRegionalChatServiceDirectly() {
        let skype = token(["skypeid": "orgid:me", "exp": 1_900_000_000, "rgn": "EMEA"])
        let direct = TeamsWebData.session(url: "https://emea.ng.msg.teams.microsoft.com/v1/users/ME/conversations?pageSize=20",
                                          header: "skypetoken=" + skype)
        XCTAssertEqual(direct?.base, "https://emea.ng.msg.teams.microsoft.com")
        XCTAssertNil(TeamsWebData.session(url: "https://evil.example.com/v1/users/ME/conversations", header: "skypetoken=" + skype),
                     "only Teams' own chat service")
        let directOnly: [String: Any] = ["tokens": ["skypeToken": skype],
                                         "regionGtms": ["chatService": "https://amer.ng.msg.teams.microsoft.com/"]]
        XCTAssertEqual(TeamsWebData.session(authz: directOnly)?.base, "https://amer.ng.msg.teams.microsoft.com")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(TeamsWebData.isSkypeToken(skype, now: now))
        XCTAssertFalse(TeamsWebData.isSkypeToken(token(["aud": "https://api.spaces.skype.com"]), now: now))
        XCTAssertFalse(TeamsWebData.isSkypeToken(token(["skypeid": "orgid:me", "exp": 1]), now: now), "run out")
        XCTAssertEqual(TeamsWebData.region(skype), "emea")
        XCTAssertEqual(TeamsWebData.session(skypeToken: skype, region: "emea")?.base, "https://teams.microsoft.com/api/chatsvc/emea")

        let spaces = token(["aud": "https://api.spaces.skype.com", "exp": 1_900_000_000])
        let cache = #"{"credentialType":"AccessToken","target":"https://api.spaces.skype.com/.default","secret":"\#(spaces)"}"#
        XCTAssertEqual(TeamsWebData.tokens(in: cache + " " + cache + " " + skype), [spaces, skype], "each token once")
        XCTAssertEqual(TeamsWebData.tokens(in: "no token here"), [])
    }

    func testEveryAccountKeepsItsOwnStore() {
        func session(_ me: String, name: String = "") -> TeamsWebData.Session {
            TeamsWebData.Session(base: "https://teams.microsoft.com/api/chatsvc/emea", token: me, expires: .distantFuture,
                                 me: me, name: name)
        }
        let school = UUID(), work = UUID(), again = UUID()
        var (accounts, dropped) = TeamsWebData.keep(session("8:orgid:a", name: "Ann"), store: school, in: [])
        (accounts, dropped) = TeamsWebData.keep(session("8:orgid:b"), store: work, in: accounts)
        XCTAssertEqual(accounts.map(\.id), ["8:orgid:a", "8:orgid:b"], "a second account is added, not swapped in")
        XCTAssertEqual(dropped, [])

        (accounts, dropped) = TeamsWebData.keep(session("8:orgid:a"), store: school, in: accounts)
        XCTAssertEqual(accounts.count, 2, "a renewal stays the same account")
        XCTAssertEqual(accounts[0].session.name, "Ann", "the name it knew stays")

        (accounts, dropped) = TeamsWebData.keep(session("8:orgid:a"), store: again, in: accounts)
        XCTAssertEqual(accounts.map(\.store), [again, work], "the same account signed in once more takes the new store")
        XCTAssertEqual(dropped, [school], "its old store goes")

        (accounts, dropped) = TeamsWebData.keep(session("8:orgid:c"), store: work, in: accounts)
        XCTAssertEqual(accounts.map(\.id), ["8:orgid:a", "8:orgid:c"], "another account signed in where one was")
        XCTAssertEqual(dropped, [])
    }

    func testTheNameAndAddressComeFromTheSignInToken() {
        let base = TeamsWebData.Session(base: "b", token: "t", expires: .distantFuture, me: me)
        let named = TeamsWebData.named(base, by: token(["name": "Ann de Vries", "upn": "ann@school.nl"]))
        XCTAssertEqual(named.name, "Ann de Vries")
        XCTAssertEqual(named.email, "ann@school.nl")
        XCTAssertEqual(TeamsWebData.Account(session: named, store: UUID()).label, "Ann de Vries")
        XCTAssertNil(TeamsWebData.named(base, by: "not a token").email)
    }

    func testGoogleSignInPagesGetFirefox() {
        let now = Date(timeIntervalSince1970: 1_793_000_000) // October 2026
        XCTAssertTrue(WebSignInAgent.isGoogleSignIn(URL(string: "https://accounts.google.com/v3/signin/identifier")))
        XCTAssertFalse(WebSignInAgent.isGoogleSignIn(URL(string: "https://login.microsoftonline.com/common")))
        XCTAssertFalse(WebSignInAgent.isGoogleSignIn(URL(string: "https://accounts.google.com.evil.example")))
        let firefox = WebSignInAgent.agent(for: URL(string: "https://accounts.google.com/o/saml2"), otherwise: nil, now: now)
        XCTAssertTrue(firefox?.contains("Firefox/15") == true, firefox ?? "")
        XCTAssertNil(WebSignInAgent.agent(for: URL(string: "https://teams.microsoft.com/v2/"), otherwise: nil, now: now))
        XCTAssertEqual(WebSignInAgent.agent(for: URL(string: "https://www.instagram.com"), otherwise: "Own", now: now), "Own")
        XCTAssertTrue(WebSignInAgent.noPasskeysOnGoogle.contains(#"(^|\.)accounts\.google\.com$"#),
                      "passkeys are hidden on Google's sign-in pages only")
        XCTAssertTrue(WebSignInAgent.noPasskeysOnGoogle.contains("PublicKeyCredential"))
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

    func testScrollingBackFollowsOnlyTheSessionsOwnService() {
        let base = "https://teams.microsoft.com/api/chatsvc/emea"
        let back = base + "/v1/users/ME/conversations/19:abc/messages?syncState=xyz"
        XCTAssertEqual(TeamsWebData.backwardLink(["_metadata": ["backwardLink": back]], base: base), back)
        XCTAssertNil(TeamsWebData.backwardLink(["_metadata": ["backwardLink": "https://example.com/steal"]], base: base))
        XCTAssertNil(TeamsWebData.backwardLink(["_metadata": [String: Any]()], base: base), "the chat's start")
    }

    func testAnAnswerShowsWhatItQuotesAndSendsTheSameWay() {
        let chat = TeamsData.Chat(id: "19:x@unq.gbl.spaces", name: "Jan", isGroup: false, last: nil, readUntil: nil)
        let content = #"<blockquote itemscope="" itemtype="http://schema.skype.com/Reply" itemid="1700">"#
            + #"<strong itemprop="mri" itemid="8:orgid:me">Me Myself</strong><span itemprop="time" itemid="1700"></span>"#
            + #"<p itemprop="preview">3 nov 16:00 &amp; on time</p></blockquote><p>At 16:00 at the latest</p>"#
        let history: [String: Any] = ["messages": [
            ["id": "1800", "messagetype": "RichText/Html", "content": content, "from": "https://x/contacts/8:orgid:jan",
             "composetime": "2026-10-26T14:21:00.000Z",
             "properties": ["emotions": #"[{"key":"like","users":[{"mri":"8:orgid:me"},{"mri":"8:orgid:jan"}]},{"key":"1f64f_foldedhands","users":[{"mri":"8:orgid:jan"}]}]"#]],
        ]]
        let message = TeamsWebData.messages(history, chat: chat, me: me).first
        XCTAssertEqual(message?.text, "At 16:00 at the latest", "the quote is not part of the text")
        XCTAssertEqual(message?.quote, InboxQuote(id: "teams-1700", sender: "Me Myself", text: "3 nov 16:00 & on time", mine: true))
        XCTAssertEqual(message?.reactions, [InboxReaction(emoji: "👍", count: 2, mine: true), InboxReaction(emoji: "🙏", count: 1, mine: false)])

        // What Nook sends reads back as the same quote.
        let sent = TeamsWebData.replyHTML(to: "teams-1800", author: "8:orgid:jan", sender: "Jan", text: "a <b> & c")
            + TeamsWebData.html("Yes\n\nsure")
        let read = TeamsWebData.reply(sent, me: me)
        XCTAssertEqual(read.quote, InboxQuote(id: "teams-1800", sender: "Jan", text: "a <b> & c", mine: false))
        XCTAssertEqual(read.html, "<p>Yes</p><p>&nbsp;</p><p>sure</p>")
        XCTAssertNil(TeamsWebData.reply("<p>plain</p>", me: me).quote)
        let json = TeamsWebData.outgoing(html: "<p>hi</p>", name: "Me", clientMessageID: "42")
        XCTAssertEqual(json["messagetype"] as? String, "RichText/Html")
        XCTAssertEqual(json["clientmessageid"] as? String, "42")
    }

    func testReactionKeysMatchTheEmojiNookShows() {
        XCTAssertEqual(TeamsData.key(emoji: "👍"), "like")
        XCTAssertEqual(TeamsData.key(emoji: "❤"), "heart", "with or without the emoji mark")
        XCTAssertEqual(TeamsData.key(emoji: "🙏"), "1f64f")
        XCTAssertEqual(TeamsData.emoji(key: "laugh"), "😂")
        XCTAssertEqual(TeamsData.emoji(key: "1f64f_foldedhands"), "🙏")
        XCTAssertEqual(TeamsData.emoji(key: "🎉"), "🎉", "Graph writes newer reactions as the emoji itself")
        XCTAssertNil(TeamsData.emoji(key: "custom_thing"))
        XCTAssertNil(TeamsWebData.reactions(nil, me: me), "a preview without them keeps what the chat shows")
    }

    func testAPrivateChatWithoutANameIsNotNamedAfterTheAccount() {
        let blank = TeamsData.Chat(id: "a", name: "", isGroup: false, last: nil, readUntil: nil)
        let named = TeamsData.Chat(id: "b", name: "Team", isGroup: true, last: nil, readUntil: nil)
        let result = TeamsData.distinguish([[blank, named], [blank, named]], labels: ["Work", "School"])
        XCTAssertEqual(result.map { $0.map(\.name) }, [["", "Team (Work)"], ["", "Team (School)"]])
    }
}
