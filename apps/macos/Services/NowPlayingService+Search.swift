import Foundation

/// The Music tab's search: tracks in Music's library through AppleScript, or on Spotify through its Web API (Spotify's
/// AppleScript cannot search). What is found plays or goes in the queue like any other track in the tab.
extension NowPlayingService {
    /// How many tracks a search shows.
    nonisolated static let searchLimit = 40

    /// Searches the playing player for `text`, a moment after the last keystroke. An empty text clears the results.
    func search(for text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !query.isEmpty else {
            searchResult = MusicSearchResult()
            return
        }
        guard query != searchResult.query || searchResult.state != .done else { return }
        let app = current?.app ?? NowPlayingService.runningPlayerName()
        // The previous results stay while the next ones load, so the grid does not flash empty on every keystroke.
        searchResult = MusicSearchResult(query: query, state: .loading, tracks: searchResult.tracks)
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let result = await NowPlayingService.results(for: query, app: app)
            guard !Task.isCancelled, let self, self.searchResult.query == query else { return }
            self.searchResult = result
        }
    }

    /// Tracks for `query` in `app` (Spotify or Music), as the Music tab and the brain's `search_music` find them.
    static func results(for query: String, app: String?) async -> MusicSearchResult {
        switch app {
        case "Spotify":
            guard SpotifySignIn.shared.isSignedIn else { return MusicSearchResult(query: query, state: .connectSpotify) }
            do {
                let tracks = try await SpotifyWebAPI.search(query)
                return MusicSearchResult(query: query, state: .done, tracks: Array(tracks.prefix(searchLimit)))
            } catch SpotifyWebAPI.Failure.notSignedIn {
                return MusicSearchResult(query: query, state: .connectSpotify)
            } catch let SpotifyWebAPI.Failure.failed(message) {
                return MusicSearchResult(query: query, state: .failed(message))
            } catch {
                return MusicSearchResult(query: query, state: .failed(error.localizedDescription))
            }
        default:
            let tracks = await withCheckedContinuation { continuation in
                libraryQueue.async {
                    let raw = runPlayerScript(MusicScriptOutput.librarySearchScript(query, limit: searchLimit)).text
                    continuation.resume(returning: raw.map(MusicScriptOutput.tracks) ?? [])
                }
            }
            return MusicSearchResult(query: query, state: .done, tracks: tracks)
        }
    }
}
