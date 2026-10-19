import Foundation

/// Lyrics for the playing track. Synced lyrics come from lrclib.net (open, no key or account) when the user allows it;
/// otherwise the lyrics Music stores with the track, then plain lyrics from lrclib.net.
///
/// Only the title, artist, album and length of the track leave the Mac, and only while the Music tab shows lyrics.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    enum State: Equatable {
        case idle
        case loading
        case found(Lyrics)
        case notFound
        /// Online lookup is off and the player has no lyrics for this track.
        case offline
    }

    @Published private(set) var state: State = .idle
    /// The track `state` belongs to (`NowPlayingInfo.trackKey`).
    @Published private(set) var trackKey: String?

    private var cache: [String: State] = [:]
    private var cacheOrder: [String] = []
    private var task: Task<Void, Never>?

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["User-Agent": "Nook (https://github.com/IAMichan/nook)"]
        return URLSession(configuration: configuration)
    }()

    /// Loads lyrics for `info` unless they are already there. `force` looks again after a miss.
    func load(for info: NowPlayingInfo, force: Bool = false) {
        let key = info.trackKey
        let online = AppSettings.shared.onlineLyrics
        if !force, trackKey == key, state != .idle, !(state == .offline && online) { return }
        trackKey = key
        task?.cancel()
        if !force, let cached = cache[key], !(cached == .offline && online) {
            state = cached
            return
        }
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            var (result, settled) = await self.lookup(info, online: online)
            // lrclib.net fetches a track it does not have yet from other sources while the first request waits, which can
            // outlast that request; the lyrics are there moments later, so look once more before showing a miss.
            if !settled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled, self.trackKey == key else { return }
                (result, settled) = await self.lookup(info, online: online)
            }
            guard !Task.isCancelled, self.trackKey == key else { return }
            self.state = result
            // A miss after a failed request is not remembered, so the next visit looks again.
            if settled { self.remember(result, for: key) }
        }
    }

    private func remember(_ state: State, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = state
        while cacheOrder.count > 60 { cache[cacheOrder.removeFirst()] = nil }
    }

    /// The lyrics for `info`, and whether that answer is settled (`false` when a request to lrclib.net failed or timed out).
    private func lookup(_ info: NowPlayingInfo, online: Bool) async -> (State, settled: Bool) {
        let local: Lyrics? = await withCheckedContinuation { continuation in
            NowPlayingService.libraryQueue.async {
                let text = NowPlayingService.playerLyrics(app: info.app)
                let lyrics = text.map { raw -> Lyrics in
                    // Some people store LRC in Music; use its time stamps when it does.
                    let synced = LyricsParser.parseLRC(raw)
                    return Lyrics(lines: synced.isEmpty ? LyricsParser.parsePlain(raw) : synced, source: .player)
                }
                continuation.resume(returning: lyrics?.lines.isEmpty == false ? lyrics : nil)
            }
        }
        if let local, local.isSynced { return (.found(local), true) }
        guard online else { return (local.map(State.found) ?? .offline, true) }
        let (remote, settled) = await fetchRemote(info)
        if let remote, remote.isSynced || remote.instrumental { return (.found(remote), true) }
        if let local { return (.found(local), settled) }
        return (remote.map(State.found) ?? .notFound, remote != nil || settled)
    }

    /// `/api/get` with the exact track first (it also matches on length), then `/api/search` with a cleaned-up title.
    /// `settled` is `false` when one of the requests failed, so a miss may not be final.
    private func fetchRemote(_ info: NowPlayingInfo) async -> (Lyrics?, settled: Bool) {
        let duration = Double(info.duration)
        var exact = [
            URLQueryItem(name: "track_name", value: info.title),
            URLQueryItem(name: "artist_name", value: info.artist),
        ]
        if !info.album.isEmpty { exact.append(URLQueryItem(name: "album_name", value: info.album)) }
        if info.duration > 0 { exact.append(URLQueryItem(name: "duration", value: String(info.duration))) }
        var settled = true
        if !info.artist.isEmpty {
            // `/api/get` may look the track up elsewhere first, so it gets more time than the search.
            let data = await get("get", exact, timeout: 20)
            if data == nil { settled = false }
            if let record = LyricsParser.records(from: data ?? Data()).first, let lyrics = LyricsParser.lyrics(from: record) {
                return (lyrics, true)
            }
        }
        guard !Task.isCancelled else { return (nil, false) }
        var search = [URLQueryItem(name: "track_name", value: LyricsParser.cleanTitle(info.title))]
        if !info.artist.isEmpty { search.append(URLQueryItem(name: "artist_name", value: LyricsParser.primaryArtist(info.artist))) }
        let data = await get("search", search)
        if data == nil { settled = false }
        let records = LyricsParser.records(from: data ?? Data())
        return (LyricsParser.best(records, duration: duration).flatMap(LyricsParser.lyrics), settled)
    }

    /// The response body; empty for a clear miss (404), `nil` when the request failed.
    private func get(_ path: String, _ items: [URLQueryItem], timeout: TimeInterval = 8) async -> Data? {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")
        components?.queryItems = items
        guard let url = components?.url else { return Data() }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        if status == 200 { return data }
        return status == 404 ? Data() : nil
    }
}
