import Foundation
import AppKit
import AuthenticationServices

/// Spotify's Web API, for what its AppleScript cannot do: put a track in Spotify's own queue and read that queue.
/// Signing in uses the user's own Spotify app (a client ID from developer.spotify.com, with `redirectURI` added to it)
/// and PKCE, so there is no secret. Adding to the queue needs Spotify Premium; without it, or without a device playing,
/// `NowPlayingService` keeps the track in Nook's own queue instead.
enum SpotifyWebAPI {
    /// Nook's one OAuth redirect: add it to the Spotify app in the dashboard.
    static let redirectURI = MCPOAuth.redirectURI
    static let scopes = "user-read-playback-state user-modify-playback-state"
    static let dashboardURL = URL(string: "https://developer.spotify.com/dashboard")!

    typealias Failure = SpotifyResponses.Failure

    /// What Nook keeps in the Keychain after signing in.
    struct Credentials: Codable, Equatable {
        var clientID: String
        var tokens: MCPOAuth.Tokens
    }

    // MARK: Requests (pure, testable)

    static func authorizationURL(clientID: String, pkce: MCPOAuth.PKCE, state: String) -> URL? {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    static func queueRequest(uri: String, token: String) -> URLRequest? {
        var components = URLComponents(string: "https://api.spotify.com/v1/me/player/queue")
        components?.queryItems = [URLQueryItem(name: "uri", value: uri)]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Network

    /// Adds a track (`spotify:track:…` or `spotify:episode:…`) to the end of Spotify's queue.
    static func addToQueue(_ uri: String) async throws {
        _ = try await authorized { token in queueRequest(uri: uri, token: token) }
    }

    /// Spotify's own queue: what plays after the current track.
    static func queue() async throws -> [MusicTrack] {
        let data = try await authorized { token in
            guard let url = URL(string: "https://api.spotify.com/v1/me/player/queue") else { return nil }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }
        return SpotifyResponses.queueTracks(from: data)
    }

    /// Tracks on Spotify matching `query`, best match first: `pages` pages, fetched side by side.
    static func search(_ query: String, pages: Int = 3) async throws -> [MusicTrack] {
        try await withThrowingTaskGroup(of: (Int, [MusicTrack]).self) { group in
            for page in 0..<max(1, pages) {
                group.addTask {
                    let data = try await authorized { token in SpotifyResponses.searchRequest(query: query, offset: page * SpotifyResponses.searchPageSize, token: token) }
                    return (page, SpotifyResponses.searchTracks(from: data))
                }
            }
            var found: [Int: [MusicTrack]] = [:]
            for try await (page, tracks) in group { found[page] = tracks }
            var seen = Set<String>()
            return found.keys.sorted().flatMap { found[$0] ?? [] }.filter { seen.insert($0.id).inserted }
        }
    }

    /// Runs a request with a valid token; a 401 refreshes the token once and tries again.
    private static func authorized(_ make: (String) -> URLRequest?) async throws -> Data {
        for attempt in 0..<2 {
            let token = try await SpotifyAuthorizer.shared.accessToken(forceRefresh: attempt > 0)
            guard let request = make(token) else { throw Failure.failed("bad request") }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch SpotifyResponses.failure(status: status, body: data) {
            case nil: return data
            case .notSignedIn where attempt == 0: continue
            case let failure?: throw failure
            }
        }
        throw Failure.notSignedIn
    }

    static func exchange(code: String, verifier: String, clientID: String) async throws -> MCPOAuth.Tokens {
        try await tokenRequest([
            ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectURI),
            ("client_id", clientID), ("code_verifier", verifier),
        ], previousRefreshToken: nil)
    }

    static func refresh(_ credentials: Credentials) async throws -> MCPOAuth.Tokens {
        guard let refreshToken = credentials.tokens.refreshToken else { throw Failure.notSignedIn }
        return try await tokenRequest([
            ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", credentials.clientID),
        ], previousRefreshToken: refreshToken)
    }

    private static func tokenRequest(_ items: [(String, String)], previousRefreshToken: String?) async throws -> MCPOAuth.Tokens {
        guard let url = URL(string: "https://accounts.spotify.com/api/token") else { throw Failure.failed("bad request") }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = MCPOAuth.formBody(items)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        return try MCPOAuth.tokens(from: json, previousRefreshToken: previousRefreshToken)
    }
}

/// The Spotify sign-in in the Keychain, never on disk or in a log.
enum SpotifyCredentialStore {
    static let account = "music.spotify.oauth"

    static func load() -> SpotifyWebAPI.Credentials? {
        guard let text = Keychain.read(account) else { return nil }
        return try? JSONDecoder().decode(SpotifyWebAPI.Credentials.self, from: Data(text.utf8))
    }

    @discardableResult
    static func save(_ credentials: SpotifyWebAPI.Credentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials), let text = String(data: data, encoding: .utf8) else { return false }
        return Keychain.write(text, account: account) == errSecSuccess
    }

    static func remove() {
        Keychain.remove(account)
    }
}

/// One refresh at a time: Spotify may rotate the refresh token, so two requests must not each spend it.
actor SpotifyAuthorizer {
    static let shared = SpotifyAuthorizer()
    private var refreshing: Task<SpotifyWebAPI.Credentials, Error>?

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let credentials = SpotifyCredentialStore.load() else { throw SpotifyWebAPI.Failure.notSignedIn }
        guard forceRefresh || credentials.tokens.needsRefresh() else { return credentials.tokens.accessToken }
        if let refreshing { return try await refreshing.value.tokens.accessToken }
        let task = Task { () throws -> SpotifyWebAPI.Credentials in
            var updated = credentials
            updated.tokens = try await SpotifyWebAPI.refresh(credentials)
            SpotifyCredentialStore.save(updated)
            return updated
        }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value.tokens.accessToken
    }
}

/// Signs in to Spotify from Settings and tells it how that is going.
@MainActor
final class SpotifySignIn: NSObject, ObservableObject {
    static let shared = SpotifySignIn()

    enum Phase: Equatable {
        case idle, waiting, failed(String)
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var isSignedIn = SpotifyCredentialStore.load() != nil
    private var session: ASWebAuthenticationSession?

    func signIn(clientID: String) {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        phase = .waiting
        Task {
            do {
                let pkce = MCPOAuth.PKCE.make()
                let state = MCPOAuth.randomToken()
                guard let url = SpotifyWebAPI.authorizationURL(clientID: id, pkce: pkce, state: state) else {
                    throw SpotifyWebAPI.Failure.failed("bad client ID")
                }
                let callback = try await present(url)
                switch MCPOAuth.parseCallback(callback, expectedState: state, issuer: nil) {
                case .failed(let error): throw error
                case .code(let code):
                    let tokens = try await SpotifyWebAPI.exchange(code: code, verifier: pkce.verifier, clientID: id)
                    guard SpotifyCredentialStore.save(.init(clientID: id, tokens: tokens)) else {
                        throw NookError(tr("connect.error.keychain"), kind: .config)
                    }
                }
                isSignedIn = true
                phase = .idle
            } catch MCPOAuthError.cancelled {
                phase = .idle
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        session?.cancel()
        session = nil
        if phase == .waiting { phase = .idle }
    }

    func signOut() {
        SpotifyCredentialStore.remove()
        isSignedIn = false
        phase = .idle
    }

    /// Spotify's sign-in page in a system window that shares the browser's login; it catches the redirect to `nook://`.
    private func present(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: MCPOAuth.callbackScheme) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: MCPOAuthError.cancelled)
                } else {
                    continuation.resume(throwing: MCPOAuthError.callbackFailed(error?.localizedDescription ?? "no answer"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() {
                continuation.resume(throwing: MCPOAuthError.callbackFailed("the sign-in window did not open"))
            }
        }
    }
}

extension SpotifySignIn: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        }
    }
}
