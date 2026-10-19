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
            let result = await self.lookup(info, online: online)
            guard !Task.isCancelled, self.trackKey == key else { return }
            self.state = result
            self.remember(result, for: key)
        }
    }

    private func remember(_ state: State, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = state
        while cacheOrder.count > 60 { cache[cacheOrder.removeFirst()] = nil }
    }

    private func lookup(_ info: NowPlayingInfo, online: Bool) async -> State {
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
        if let local, local.isSynced { return .found(local) }
        guard online else { return local.map(State.found) ?? .offline }
        let remote = await fetchRemote(info)
        if let remote, remote.isSynced || remote.instrumental { return .found(remote) }
        if let local { return .found(local) }
        return remote.map(State.found) ?? .notFound
    }

    /// `/api/get` with the exact track first (it also matches on length), then `/api/search` with a cleaned-up title.
    private func fetchRemote(_ info: NowPlayingInfo) async -> Lyrics? {
        let duration = Double(info.duration)
        var exact = [
            URLQueryItem(name: "track_name", value: info.title),
            URLQueryItem(name: "artist_name", value: info.artist),
        ]
        if !info.album.isEmpty { exact.append(URLQueryItem(name: "album_name", value: info.album)) }
        if info.duration > 0 { exact.append(URLQueryItem(name: "duration", value: String(info.duration))) }
        if !info.artist.isEmpty, let record = LyricsParser.records(from: await get("get", exact)).first,
           let lyrics = LyricsParser.lyrics(from: record) {
            return lyrics
        }
        guard !Task.isCancelled else { return nil }
        var search = [URLQueryItem(name: "track_name", value: LyricsParser.cleanTitle(info.title))]
        if !info.artist.isEmpty { search.append(URLQueryItem(name: "artist_name", value: LyricsParser.primaryArtist(info.artist))) }
        let records = LyricsParser.records(from: await get("search", search))
        return LyricsParser.best(records, duration: duration).flatMap(LyricsParser.lyrics)
    }

    private func get(_ path: String, _ items: [URLQueryItem]) async -> Data {
        var components = URLComponents(string: "https://lrclib.net/api/\(path)")
        components?.queryItems = items
        guard let url = components?.url else { return Data() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return Data() }
        return data
    }
}
