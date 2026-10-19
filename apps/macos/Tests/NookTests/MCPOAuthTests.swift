import XCTest

/// Signing in to MCP servers: PKCE, the authorization request, checking the callback (state, redirect, issuer) and
/// reading token responses. No network: these are the parts that keep the sign-in safe.
final class MCPOAuthTests: XCTestCase {
    private let server = MCPOAuth.ServerMetadata(
        issuer: "https://auth.example.com",
        authorizationEndpoint: "https://auth.example.com/authorize",
        tokenEndpoint: "https://auth.example.com/token",
        registrationEndpoint: "https://auth.example.com/register",
        codeChallengeMethods: ["S256"]
    )

    // MARK: PKCE

    func testChallengeMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        XCTAssertEqual(MCPOAuth.PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testVerifiersAreLongURLSafeAndUnique() {
        let a = MCPOAuth.PKCE.make(), b = MCPOAuth.PKCE.make()
        XCTAssertNotEqual(a.verifier, b.verifier)
        XCTAssertEqual(a.verifier.count, 43)
        XCTAssertTrue(a.verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertEqual(a.challenge, MCPOAuth.PKCE.challenge(for: a.verifier))
    }

    // MARK: Authorization request

    func testAuthorizationURLCarriesPKCEStateAndResource() throws {
        let pkce = MCPOAuth.PKCE.make()
        let url = try XCTUnwrap(MCPOAuth.authorizationURL(server: server, client: .init(id: "client+1", secret: nil), pkce: pkce,
                                                         state: "s1", resource: "https://mcp.example.com/mcp", scope: "read write"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], "client+1")
        XCTAssertEqual(items["redirect_uri"], MCPOAuth.redirectURI)
        XCTAssertEqual(items["code_challenge"], pkce.challenge)
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "s1")
        XCTAssertEqual(items["resource"], "https://mcp.example.com/mcp")
        XCTAssertEqual(items["scope"], "read write")
        XCTAssertFalse(url.absoluteString.contains("client+1"), "a literal + would be read as a space")
    }

    // MARK: Callback

    func testCallbackWithMatchingStateGivesTheCode() {
        let url = URL(string: "nook://oauth/callback?code=abc&state=xyz")!
        XCTAssertEqual(MCPOAuth.parseCallback(url, expectedState: "xyz", issuer: nil), .code("abc"))
    }

    func testCallbackWithOtherStateIsRejected() {
        let url = URL(string: "nook://oauth/callback?code=abc&state=forged")!
        XCTAssertEqual(MCPOAuth.parseCallback(url, expectedState: "xyz", issuer: nil), .failed(.stateMismatch))
    }

    func testCallbackWithoutStateIsRejected() {
        let url = URL(string: "nook://oauth/callback?code=abc")!
        XCTAssertEqual(MCPOAuth.parseCallback(url, expectedState: "xyz", issuer: nil), .failed(.stateMismatch))
    }

    func testDeniedConsentIsReportedAsDeclined() {
        let url = URL(string: "nook://oauth/callback?error=access_denied&state=xyz")!
        XCTAssertEqual(MCPOAuth.parseCallback(url, expectedState: "xyz", issuer: nil), .failed(.declined))
    }

    func testOtherRedirectTargetsAreRejected() {
        let url = URL(string: "nook://evil/callback?code=abc&state=xyz")!
        guard case .failed(.callbackFailed) = MCPOAuth.parseCallback(url, expectedState: "xyz", issuer: nil) else {
            return XCTFail("a redirect to another path must not be accepted")
        }
    }

    func testIssuerMismatchIsRejected() {
        let url = URL(string: "nook://oauth/callback?code=abc&state=xyz&iss=https://other.example.com")!
        guard case .failed(.callbackFailed) = MCPOAuth.parseCallback(url, expectedState: "xyz", issuer: server.issuer) else {
            return XCTFail("a code from another issuer must not be accepted")
        }
        let good = URL(string: "nook://oauth/callback?code=abc&state=xyz&iss=https://auth.example.com")!
        XCTAssertEqual(MCPOAuth.parseCallback(good, expectedState: "xyz", issuer: server.issuer), .code("abc"))
    }

    // MARK: Tokens

    func testTokenResponseSetsExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let tokens = try MCPOAuth.tokens(from: ["access_token": "a", "refresh_token": "r", "expires_in": 3600, "token_type": "Bearer"], now: now)
        XCTAssertEqual(tokens.accessToken, "a")
        XCTAssertEqual(tokens.refreshToken, "r")
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
        XCTAssertFalse(tokens.needsRefresh(now: now))
        XCTAssertTrue(tokens.needsRefresh(now: now.addingTimeInterval(3570)))
    }

    func testRefreshWithoutNewRefreshTokenKeepsTheOldOne() throws {
        let tokens = try MCPOAuth.tokens(from: ["access_token": "a2", "expires_in": 60], previousRefreshToken: "r1")
        XCTAssertEqual(tokens.refreshToken, "r1")
    }

    func testInvalidGrantMeansExpired() {
        XCTAssertThrowsError(try MCPOAuth.tokens(from: ["error": "invalid_grant"])) { error in
            XCTAssertEqual(error as? MCPOAuthError, .expired)
        }
    }

    func testNonBearerTokensAreRefused() {
        XCTAssertThrowsError(try MCPOAuth.tokens(from: ["access_token": "a", "token_type": "mac"]))
    }

    // MARK: Discovery

    func testResourceMetadataFromWWWAuthenticate() {
        let header = #"Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="files:read""#
        XCTAssertEqual(MCPOAuth.authenticateParameter("resource_metadata", in: header), "https://mcp.example.com/.well-known/oauth-protected-resource")
        XCTAssertEqual(MCPOAuth.authenticateParameter("scope", in: header), "files:read")
        XCTAssertNil(MCPOAuth.authenticateParameter("missing", in: header))
    }

    func testWellKnownCandidates() {
        let resource = MCPOAuth.resourceMetadataCandidates(for: URL(string: "https://mcp.example.com/mcp")!).map(\.absoluteString)
        XCTAssertEqual(resource, ["https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
                                  "https://mcp.example.com/.well-known/oauth-protected-resource"])
        let rootServer = MCPOAuth.serverMetadataCandidates(issuer: URL(string: "https://auth.example.com")!).map(\.absoluteString)
        XCTAssertEqual(rootServer, ["https://auth.example.com/.well-known/oauth-authorization-server",
                                    "https://auth.example.com/.well-known/openid-configuration"])
        let tenant = MCPOAuth.serverMetadataCandidates(issuer: URL(string: "https://auth.example.com/tenant1")!).map(\.absoluteString)
        XCTAssertEqual(tenant.first, "https://auth.example.com/.well-known/oauth-authorization-server/tenant1")
        XCTAssertEqual(tenant.count, 3)
    }

    func testCanonicalResource() {
        XCTAssertEqual(MCPOAuth.canonicalResource(URL(string: "HTTPS://MCP.Example.com/mcp/?x=1#f")!), "https://mcp.example.com/mcp")
        XCTAssertEqual(MCPOAuth.canonicalResource(URL(string: "https://mcp.example.com:8443")!), "https://mcp.example.com:8443")
    }

    func testServerMetadataRules() {
        XCTAssertTrue(server.isSecure)
        XCTAssertTrue(server.supportsS256)
        var plain = server
        plain.codeChallengeMethods = ["plain"]
        XCTAssertFalse(plain.supportsS256)
        var insecure = server
        insecure.tokenEndpoint = "http://auth.example.com/token"
        XCTAssertFalse(insecure.isSecure)
        let parsed = MCPOAuth.ServerMetadata(["authorization_endpoint": "https://a/authorize", "token_endpoint": "https://a/token"],
                                             fallbackIssuer: "https://a")
        XCTAssertEqual(parsed?.issuer, "https://a")
        XCTAssertNil(MCPOAuth.ServerMetadata(["token_endpoint": "https://a/token"], fallbackIssuer: "https://a"))
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = String(data: MCPOAuth.formBody([("code", "a+b/c=d&e"), ("redirect_uri", "nook://oauth/callback")]), encoding: .utf8)
        XCTAssertEqual(body, "code=a%2Bb%2Fc%3Dd%26e&redirect_uri=nook%3A%2F%2Foauth%2Fcallback")
    }

    func testConstantTimeCompare() {
        XCTAssertTrue(MCPOAuth.constantTimeEqual("abc", "abc"))
        XCTAssertFalse(MCPOAuth.constantTimeEqual("abc", "abd"))
        XCTAssertFalse(MCPOAuth.constantTimeEqual("abc", "abcd"))
    }
}
