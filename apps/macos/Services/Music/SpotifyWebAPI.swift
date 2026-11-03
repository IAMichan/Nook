import Foundation
import AppKit
import AuthenticationServices

/// Spotify's Web API, for what its AppleScript cannot do: put a track in Spotify's own queue and read that queue, search,
/// and read and keep the user's playlists.
/// Signing in uses the user's own Spotify app (a client ID from developer.spotify.com, with `redirectURI` added to it)
/// and PKCE, so there is no secret. Adding to the queue needs Spotify Premium; without it, or without a device playing,
/// `NowPlayingService` keeps the track in Nook's own queue instead.
enum SpotifyWebAPI {
    /// Nook's one OAuth redirect: add it to the Spotify app in the dashboard.
    static let redirectURI = MCPOAuth.redirectURI
    /// Playback for the queue; the playlist scopes for the Music tab's playlists. A sign-in made before Nook asked for
    /// the playlist scopes gets `Failure.missingScope` and must connect again.
    static let scopes = [
        "user-read-playback-state", "user-modify-playback-state",
        "playlist-read-private", "playlist-read-collaborative", "playlist-modify-private", "playlist-modify-public",
        "user-library-modify",
    ].joined(separator: " ")
    private static let base = "https://api.spotify.com/v1"
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

    // MARK: Playlists

    /// How many playlists and tracks per playlist Nook reads at most.
    static let playlistLimit = 200
    static let playlistTrackLimit = 500

    /// The user's own id, read once per session: it tells their own playlists from those they follow.
    static func userID() async throws -> String? {
        if let known = await SpotifyAuthorizer.shared.userID { return known }
        let data = try await get("\(base)/me")
        let id = SpotifyResponses.userID(from: data)
        await SpotifyAuthorizer.shared.setUserID(id)
        return id
    }

    /// The user's playlists, their own and those they follow, in Spotify's order.
    static func playlists() async throws -> [MusicPlaylist] {
        let me = try await userID()
        var result: [MusicPlaylist] = []
        var next = URL(string: "\(base)/me/playlists?limit=50")
        while let url = next, result.count < playlistLimit {
            let data = try await get(url.absoluteString)
            result += SpotifyResponses.playlists(from: data, userID: me)
            next = SpotifyResponses.nextPage(from: data)
        }
        return Array(result.prefix(playlistLimit))
    }

    /// The tracks of a playlist, in its order.
    static func playlistTracks(_ playlist: MusicPlaylist) async throws -> [MusicTrack] {
        let id = try bareID(playlist)
        var result: [MusicTrack] = []
        // Spotify moved a playlist's tracks from `/tracks` to `/items` in 2026: the new path first, the old one when
        // it is not there (yet).
        var next = try await firstAvailable(["\(base)/playlists/\(id)/items?limit=50", "\(base)/playlists/\(id)/tracks?limit=50"]) { $0 }
        while true {
            result += SpotifyResponses.playlistTracks(from: next.data)
            guard result.count < playlistTrackLimit, let url = SpotifyResponses.nextPage(from: next.data) else { break }
            next = (try await get(url.absoluteString), url.absoluteString)
        }
        return Array(result.prefix(playlistTrackLimit))
    }

    /// Adds a track to the end of a playlist the user may edit.
    static func add(_ trackURI: String, to playlist: MusicPlaylist) async throws {
        let id = try bareID(playlist)
        _ = try await firstAvailable(["\(base)/playlists/\(id)/items", "\(base)/playlists/\(id)/tracks"]) { url in
            (url, "POST", ["uris": [trackURI]])
        }
    }

    /// Takes every occurrence of a track out of a playlist.
    static func remove(_ trackURI: String, from playlist: MusicPlaylist) async throws {
        let id = try bareID(playlist)
        _ = try await firstAvailable(["\(base)/playlists/\(id)/items", "\(base)/playlists/\(id)/tracks"]) { url in
            (url, "DELETE", [url.hasSuffix("/items") ? "items" : "tracks": [["uri": trackURI]]])
        }
    }

    /// Makes a new private playlist for the user.
    static func createPlaylist(named name: String) async throws -> MusicPlaylist {
        let me = try await userID()
        var urls = ["\(base)/me/playlists"]
        if let me { urls.append("\(base)/users/\(me)/playlists") }
        let answer = try await firstAvailable(urls) { url in (url, "POST", ["name": name, "public": false]) }
        guard let json = try? JSONSerialization.jsonObject(with: answer.data) as? [String: Any],
              let playlist = SpotifyResponses.playlist(json, userID: me) else { throw Failure.failed("no playlist in the answer") }
        return playlist
    }

    static func rename(_ playlist: MusicPlaylist, to name: String) async throws {
        let id = try bareID(playlist)
        _ = try await send("\(base)/playlists/\(id)", method: "PUT", json: ["name": name])
    }

    /// Removes a playlist from the user's library (Spotify's "delete": the playlist stays for those who follow it).
    static func delete(_ playlist: MusicPlaylist) async throws {
        let id = try bareID(playlist)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":")
        let uri = playlist.id.addingPercentEncoding(withAllowedCharacters: allowed) ?? playlist.id
        _ = try await firstAvailable(["\(base)/playlists/\(id)/followers", "\(base)/me/library?uris=\(uri)"]) { url in
            (url, "DELETE", nil)
        }
    }

    private static func bareID(_ playlist: MusicPlaylist) throws -> String {
        guard let id = SpotifyResponses.playlistID(playlist.id) else { throw Failure.failed("not a Spotify playlist") }
        return id
    }

    private static func get(_ url: String) async throws -> Data {
        try await send(url, method: "GET", json: nil)
    }

    private static func send(_ url: String, method: String, json: [String: Any]?) async throws -> Data {
        try await authorized { token in
            URL(string: url).map { SpotifyResponses.request($0, method: method, json: json, token: token) }
        }
    }

    /// Tries each URL in turn while Spotify answers 404 (the path does not exist): for endpoints Spotify moved.
    private static func firstAvailable(_ urls: [String], _ make: (String) -> (String, String, [String: Any]?)) async throws -> (data: Data, url: String) {
        var lastError: Error = Failure.failed("no endpoint")
        for url in urls {
            let (address, method, json) = make(url)
            do {
                return (try await send(address, method: method, json: json), address)
            } catch Failure.noActiveDevice {
                lastError = Failure.failed("HTTP 404")
                continue
            }
        }
        throw lastError
    }

    private static func firstAvailable(_ urls: [String], _ make: (String) -> String) async throws -> (data: Data, url: String) {
        try await firstAvailable(urls) { (make($0), "GET", nil) }
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
    /// The signed-in user's Spotify id, once read (`SpotifyWebAPI.userID`).
    private(set) var userID: String?

    func setUserID(_ id: String?) { userID = id }

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
                await SpotifyAuthorizer.shared.setUserID(nil)
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
        Task { await SpotifyAuthorizer.shared.setUserID(nil) }
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
