import XCTest

/// Nook in another app: the access levels, the sign-in with a pairing code, the 30-day grants, and the HTTP side.
final class RemoteMCPTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let redirect = "https://claude.ai/api/mcp/auth_callback"
    private let verifier = "v-" + String(repeating: "a", count: 50)

    /// Known "random" values, one after another.
    private func random() -> RemoteMCPAccess.Random {
        var counter = 0
        return .init(secret: { size in
            counter += 1
            return String(repeating: String(counter % 10), count: size * 2)
        }, digits: { _ in "123456" })
    }

    private func registered(_ access: inout RemoteMCPAccess, _ random: RemoteMCPAccess.Random) -> String {
        guard case .success(let client) = access.register(name: "Claude", redirects: [redirect], now: now, random: random) else {
            XCTFail("registration")
            return ""
        }
        return client.id
    }

    private func begin(_ access: inout RemoteMCPAccess, _ client: String, _ random: RemoteMCPAccess.Random) -> RemoteMCPAccess.SignIn? {
        if case .success(let signIn) = access.begin(clientID: client, redirect: redirect, responseType: "code", state: "s1",
                                                    challenge: RemoteMCP.challenge(verifier: verifier), method: "S256", now: now, random: random) {
            return signIn
        }
        return nil
    }

    // MARK: Levels

    func testLevelsGrowAndNeverOfferWhatNeedsAFolder() {
        XCTAssertTrue(RemoteAccessLevel.readOnly.tools.isSubset(of: RemoteAccessLevel.sessions.tools))
        XCTAssertTrue(RemoteAccessLevel.sessions.tools.isSubset(of: RemoteAccessLevel.full.tools))
        XCTAssertTrue(RemoteAccessLevel.readOnly.allows(.sessionList))
        XCTAssertFalse(RemoteAccessLevel.readOnly.allows(.sessionSend))
        XCTAssertTrue(RemoteAccessLevel.sessions.allows(.sessionSend))
        XCTAssertFalse(RemoteAccessLevel.sessions.allows(.nookUse))
        XCTAssertTrue(RemoteAccessLevel.full.allows(.nookUse))
        let never: [BridgeTool] = [.terminalRun, .terminalRead, .browserOpen, .deviceOpen, .renderPage, .requestSecret, .takeOverScreen,
                                   .pullRequestCreate, .delegateTask]
        for level in RemoteAccessLevel.allCases { for tool in never { XCTAssertFalse(level.allows(tool), "\(level) \(tool)") } }
    }

    func testReadOnlyHasOnlyReads() {
        for tool in RemoteAccessLevel.readOnly.tools { XCTAssertEqual(tool.effect, .read, tool.rawValue) }
    }

    func testToolsAreListedAndCalledOnlyWithinTheLevel() async {
        let list = await BridgeRPC.response(to: ["id": 1, "method": "tools/list"], offered: RemoteAccessLevel.readOnly.offered) { _, _ in .error("") }
        let names = ((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertTrue(names.contains("session_list"))
        XCTAssertFalse(names.contains("session_send"))
        var called = false
        let reply = await BridgeRPC.response(to: ["id": 2, "method": "tools/call", "params": ["name": "session_send", "arguments": [:]]],
                                             offered: RemoteAccessLevel.readOnly.offered) { _, _ in called = true; return .error("") }
        XCTAssertFalse(called)
        XCTAssertNotNil(reply?["error"])
    }

    // MARK: Sign-in

    func testSignInNeedsAKnownClientAnExactRedirectAndPKCE() {
        var access = RemoteMCPAccess()
        let random = random()
        let client = registered(&access, random)
        XCTAssertEqual(access.begin(clientID: "nope", redirect: redirect, responseType: "code", state: nil, challenge: "c", method: "S256", now: now, random: random).failure, .invalidClient)
        XCTAssertEqual(access.begin(clientID: client, redirect: redirect + "/x", responseType: "code", state: nil, challenge: "c", method: "S256", now: now, random: random).failure, .invalidClient)
        XCTAssertEqual(access.begin(clientID: client, redirect: redirect, responseType: "token", state: nil, challenge: "c", method: "S256", now: now, random: random).failure, .unsupported)
        XCTAssertEqual(access.begin(clientID: client, redirect: redirect, responseType: "code", state: nil, challenge: nil, method: nil, now: now, random: random).failure, .invalidRequest)
        XCTAssertEqual(access.begin(clientID: client, redirect: redirect, responseType: "code", state: nil, challenge: "c", method: "plain", now: now, random: random).failure, .invalidRequest)
        XCTAssertTrue(access.waiting.isEmpty)
    }

    func testRedirectsMustBeHTTPSOrLocal() {
        XCTAssertTrue(RemoteMCP.isValidRedirect("https://chatgpt.com/connector/oauth/abc"))
        XCTAssertTrue(RemoteMCP.isValidRedirect("http://localhost:3000/callback"))
        XCTAssertFalse(RemoteMCP.isValidRedirect("http://evil.example/callback"))
        XCTAssertFalse(RemoteMCP.isValidRedirect("javascript:alert(1)"))
        XCTAssertFalse(RemoteMCP.isValidRedirect("https://a.example/cb#frag"))
        XCTAssertFalse(RemoteMCP.isValidRedirect("https://user:pw@a.example/cb"))
    }

    func testTheCodeFromNookIsWhatLetsTheAssistantIn() {
        var access = RemoteMCPAccess()
        let random = random()
        let client = registered(&access, random)
        let signIn = begin(&access, client, random)!
        XCTAssertEqual(signIn.code, "123456")
        XCTAssertEqual(RemoteMCP.display(code: signIn.code), "123 456")
        XCTAssertEqual(access.confirm(signIn.id, typed: "000 000", now: now, random: random), .wrong(attemptsLeft: 4))
        guard case .approved(let location) = access.confirm(signIn.id, typed: "123 456", now: now, random: random) else { return XCTFail("approved") }
        XCTAssertTrue(location.hasPrefix(redirect + "?code="))
        XCTAssertTrue(location.hasSuffix("&state=s1"))
        XCTAssertTrue(access.waiting.isEmpty)
        XCTAssertEqual(access.confirm(signIn.id, typed: "123456", now: now, random: random), .gone, "a sign-in is used once")
    }

    func testTooManyWrongCodesEndTheSignIn() {
        var access = RemoteMCPAccess()
        let random = random()
        let signIn = begin(&access, registered(&access, random), random)!
        for _ in 0..<(RemoteMCP.maxAttempts - 1) { _ = access.confirm(signIn.id, typed: "999999", now: now, random: random) }
        XCTAssertEqual(access.confirm(signIn.id, typed: "999999", now: now, random: random), .gone)
        XCTAssertEqual(access.confirm(signIn.id, typed: "123456", now: now, random: random), .gone, "the right code is too late")
    }

    func testASignInThatWaitsTooLongIsDropped() {
        var access = RemoteMCPAccess()
        let random = random()
        let signIn = begin(&access, registered(&access, random), random)!
        let late = now.addingTimeInterval(RemoteMCP.signInLifetime + 1)
        XCTAssertEqual(access.confirm(signIn.id, typed: "123456", now: late, random: random), .gone)
    }

    func testOnlyAFewSignInsWaitAtOnce() {
        var access = RemoteMCPAccess()
        let random = random()
        let client = registered(&access, random)
        for _ in 0..<RemoteMCP.maxWaiting { XCTAssertNotNil(begin(&access, client, random)) }
        XCTAssertNil(begin(&access, client, random))
    }

    // MARK: Tokens and grants

    private func signedIn(_ access: inout RemoteMCPAccess, level: RemoteAccessLevel = .sessions) -> (RemoteMCPAccess.Tokens, String) {
        let random = random()
        let client = registered(&access, random)
        let signIn = begin(&access, client, random)!
        access.setLevel(level, for: signIn.id)
        guard case .approved(let location) = access.confirm(signIn.id, typed: "123456", now: now, random: random),
              let code = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "code" })?.value else { fatalError("no code") }
        guard case .success(let tokens) = access.exchange(code: code, verifier: verifier, clientID: client, redirect: redirect, now: now, random: random) else {
            fatalError("no tokens")
        }
        return (tokens, client)
    }

    func testTheCodeBuysTokensOnceAndOnlyWithTheVerifier() {
        var access = RemoteMCPAccess()
        let random = random()
        let client = registered(&access, random)
        let signIn = begin(&access, client, random)!
        guard case .approved(let location) = access.confirm(signIn.id, typed: "123456", now: now, random: random),
              let code = URLComponents(string: location)?.queryItems?.first(where: { $0.name == "code" })?.value else { return XCTFail("code") }
        XCTAssertEqual(access.exchange(code: code, verifier: "wrong", clientID: client, redirect: redirect, now: now, random: random).failure, .invalidGrant)
        XCTAssertEqual(access.exchange(code: code, verifier: verifier, clientID: client, redirect: redirect, now: now, random: random).failure, .invalidGrant,
                       "a wrong attempt spends the code")
    }

    func testAGrantLastsThirtyDaysAndTokensAreOnlyKeptAsHashes() {
        var access = RemoteMCPAccess()
        let (tokens, _) = signedIn(&access)
        let grant = access.grant(accessToken: tokens.access, now: now)
        XCTAssertEqual(grant?.level, .sessions)
        XCTAssertEqual(grant?.expires, now.addingTimeInterval(30 * 24 * 3600))
        XCTAssertNotEqual(grant?.accessHash, tokens.access)
        XCTAssertNil(access.grant(accessToken: tokens.access, now: now.addingTimeInterval(RemoteMCP.accessLifetime + 1)), "an access token is short")
        XCTAssertNil(access.grant(accessToken: "nka_guess", now: now))
    }

    func testRefreshRenewsTheAccessTokenButNeverTheGrant() {
        var access = RemoteMCPAccess()
        let (tokens, client) = signedIn(&access)
        let later = now.addingTimeInterval(RemoteMCP.accessLifetime + 60)
        guard case .success(let fresh) = access.refresh(token: tokens.refresh, clientID: client, now: later, random: random()) else { return XCTFail("refresh") }
        XCTAssertNotNil(access.grant(accessToken: fresh.access, now: later))
        XCTAssertNil(access.grant(accessToken: tokens.access, now: later))
        XCTAssertEqual(access.refresh(token: tokens.refresh, clientID: client, now: later, random: random()).failure, .invalidGrant, "a refresh token works once")
        let end = now.addingTimeInterval(RemoteMCP.grantLifetime + 1)
        XCTAssertEqual(access.refresh(token: fresh.refresh, clientID: client, now: end, random: random()).failure, .invalidGrant)
        XCTAssertNil(access.grant(accessToken: fresh.access, now: end))
    }

    func testRevokingEndsAccessAtOnceAndALowerLevelCountsFromNow() {
        var access = RemoteMCPAccess()
        let (tokens, _) = signedIn(&access, level: .full)
        let id = access.grant(accessToken: tokens.access, now: now)!.id
        access.setLevel(.readOnly, forGrant: id)
        XCTAssertEqual(access.grant(accessToken: tokens.access, now: now)?.level, .readOnly)
        access.revoke(id)
        XCTAssertNil(access.grant(accessToken: tokens.access, now: now))
        XCTAssertTrue(access.grants.isEmpty)
    }

    func testGrantsSurviveSavingAsJSON() throws {
        var access = RemoteMCPAccess()
        _ = signedIn(&access)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode([RemoteMCPAccess.Grant].self, from: encoder.encode(access.grants))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back.first?.accessHash, access.grants.first?.accessHash)
    }

    func testPKCEMatchesTheRFCExample() {
        XCTAssertEqual(RemoteMCP.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    // MARK: HTTP

    private func request(_ method: String, _ path: String, query: String = "", body: String = "", headers: [String: String] = [:]) -> RemoteMCPHTTP.Request {
        .init(id: "1", method: method, path: path, query: query, headers: headers, body: Data(body.utf8))
    }

    func testTheDiscoveryDocumentsPointAtTheRoom() throws {
        var access = RemoteMCPAccess()
        let base = "https://relay.example/v1/mcp/" + String(repeating: "a", count: 32)
        let resource = RemoteMCPHTTP.oauth(request("GET", "/.well-known/oauth-protected-resource"), access: &access, base: base, now: now, random: random(), texts: { $0 })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(resource).body) as? [String: Any])
        XCTAssertEqual(object["resource"] as? String, base)
        let server = RemoteMCPHTTP.oauth(request("GET", "/.well-known/oauth-authorization-server"), access: &access, base: base, now: now, random: random(), texts: { $0 })
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server).body) as? [String: Any])
        XCTAssertEqual(document["token_endpoint"] as? String, base + "/token")
        XCTAssertEqual(document["code_challenge_methods_supported"] as? [String], ["S256"])
    }

    func testTheFullFlowOverHTTP() throws {
        var access = RemoteMCPAccess()
        let base = "https://relay.example/v1/mcp/" + String(repeating: "b", count: 32)
        let random = random()
        let texts: RemoteMCPHTTP.Texts = { $0 == "remotemcp.page.intro" ? "%@ asks" : $0 }
        let registration = try XCTUnwrap(RemoteMCPHTTP.oauth(request("POST", "/register", body: #"{"client_name":"ChatGPT","redirect_uris":["\#(redirect)"]}"#),
                                                             access: &access, base: base, now: now, random: random, texts: texts))
        XCTAssertEqual(registration.status, 201)
        let client = try XCTUnwrap((JSONSerialization.jsonObject(with: registration.body) as? [String: Any])?["client_id"] as? String)
        let query = "response_type=code&client_id=\(client)&redirect_uri=\(redirect)&state=xyz&code_challenge=\(RemoteMCP.challenge(verifier: verifier))&code_challenge_method=S256"
        let page = try XCTUnwrap(RemoteMCPHTTP.oauth(request("GET", "/authorize", query: query), access: &access, base: base, now: now, random: random, texts: texts))
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(String(decoding: page.body, as: UTF8.self).contains("ChatGPT"))
        XCTAssertFalse(String(decoding: page.body, as: UTF8.self).contains("123456"), "the page never shows the code")
        let id = try XCTUnwrap(access.waiting.first?.id)
        let wrong = try XCTUnwrap(RemoteMCPHTTP.oauth(request("POST", "/authorize", body: "id=\(id)&code=000000"), access: &access, base: base, now: now, random: random, texts: texts))
        XCTAssertEqual(wrong.status, 200)
        let right = try XCTUnwrap(RemoteMCPHTTP.oauth(request("POST", "/authorize", body: "id=\(id)&code=123+456"), access: &access, base: base, now: now, random: random, texts: texts))
        XCTAssertEqual(right.status, 302)
        let location = try XCTUnwrap(right.headers["location"])
        let code = try XCTUnwrap(URLComponents(string: location)?.queryItems?.first { $0.name == "code" }?.value)
        let token = try XCTUnwrap(RemoteMCPHTTP.oauth(request("POST", "/token", body: "grant_type=authorization_code&code=\(code)&code_verifier=\(verifier)&client_id=\(client)&redirect_uri=\(redirect.replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F"))"),
                                                      access: &access, base: base, now: now, random: random, texts: texts))
        XCTAssertEqual(token.status, 200)
        let issued = try XCTUnwrap(JSONSerialization.jsonObject(with: token.body) as? [String: Any])
        XCTAssertEqual(issued["token_type"] as? String, "Bearer")
        XCTAssertNotNil(access.grant(accessToken: try XCTUnwrap(issued["access_token"] as? String), now: now))
        XCTAssertNil(RemoteMCPHTTP.oauth(request("POST", "/"), access: &access, base: base, now: now, random: random, texts: texts), "the MCP endpoint is not OAuth's")
    }

    func testTheRelayFramesRoundTrip() throws {
        let frame = #"{"id":"7","method":"post","path":"/","query":"a=1","headers":{"Authorization":"Bearer x"},"body":"e30="}"#
        let parsed = try XCTUnwrap(RemoteMCPHTTP.incoming(frame))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(RemoteMCPHTTP.bearer(parsed), "x")
        XCTAssertNil(RemoteMCPHTTP.incoming("nonsense"))
        let answer = RemoteMCPHTTP.frame(id: "7", .init(status: 202, headers: [:], body: Data("ok".utf8)))
        XCTAssertTrue(answer.contains(#""status":202"#))
    }

    func testThePageEscapesWhatTheAssistantNamesItself() {
        var access = RemoteMCPAccess()
        let random = random()
        guard case .success(let client) = access.register(name: "<script>x</script>", redirects: [redirect], now: now, random: random) else { return XCTFail() }
        let signIn = begin(&access, client.id, random)!
        let html = String(decoding: RemoteMCPHTTP.page(signIn: signIn, error: nil, base: "https://r/v1/mcp/x", texts: { $0 == "remotemcp.page.intro" ? "%@ asks" : $0 }).body, as: UTF8.self)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testTheTunnelRoomHidesTheToken() {
        let token = String(repeating: "x", count: 40)
        let room = RemoteMCPTunnel.room(token: token)
        XCTAssertEqual(room.count, 32)
        XCTAssertFalse(room.contains(token))
        XCTAssertTrue(RemoteMCPTunnel.listenURL(relay: "https://r.example", token: token)?.absoluteString.hasPrefix("wss://r.example/v1/mcp/\(room)/listen") ?? false)
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
