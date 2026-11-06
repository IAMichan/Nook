import AppKit
import Foundation

/// What Nook remembers of the listening, in one file next to its database, on this Mac only: Recent, recent searches and
/// the plays behind the statistics. Settings › Connections turns it off or clears it.
extension NowPlayingService {
    private nonisolated static var historyURL: URL { NookPaths.supportDirectory.appendingPathComponent("music-history.json") }
    /// Top lists from the player are read at most this often.
    private static let playerStatsInterval: TimeInterval = 10 * 60

    private var keepsHistory: Bool { AppSettings.shared.musicHistory }

    /// Reads the file once, off the main thread. What was heard in the meantime is kept.
    func loadHistory() {
        guard !historyLoaded else { return }
        historyLoaded = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishListening() }
        }
        Task { @MainActor [weak self] in
            let saved = await Task.detached(priority: .utility) { () -> MusicHistory? in
                guard let data = try? Data(contentsOf: Self.historyURL) else { return nil }
                return try? JSONDecoder().decode(MusicHistory.self, from: data)
            }.value
            guard let self, var merged = saved, self.keepsHistory else { return }
            for play in self.history.plays { merged.add(play) }
            for track in self.history.recent.tracks.reversed() { merged.recent.add(track) }
            self.history = merged
        }
    }

    /// Called on every change of `current`: measures the listening and keeps Recent. A track shows in Recent as soon as
    /// it starts, so what was just picked from a search is there when the user comes back.
    func noteListening(previous: NowPlayingInfo?) {
        let info = current
        // Spotify's ads are not listening.
        let measured = info.flatMap { $0.trackID.hasPrefix("spotify:ad:") ? nil : $0 }
        let draft = measured.map {
            MusicPlay(id: $0.trackID, title: $0.title, artist: $0.artist, album: $0.album, app: $0.app, artworkURL: $0.artworkURL,
                      duration: $0.duration, listened: 0, playedAt: $0.capturedAt)
        }
        if let finished = listening.update(draft, isPlaying: measured?.isPlaying == true, at: Date()) { record(finished) }
        guard let draft, previous?.trackKey != info?.trackKey else { return }
        history.recent.add(draft.track)
        saveHistorySoon()
    }

    private func record(_ play: MusicPlay) {
        guard keepsHistory else { return }
        history.add(play)
        saveHistorySoon()
    }

    private func finishListening() {
        if let finished = listening.finish(at: Date()) { record(finished) }
        guard keepsHistory else { return }
        historySaveTask?.cancel()
        Self.write(history)
    }

    /// Remembers a search the user did something with.
    func rememberSearch(_ text: String) {
        guard keepsHistory else { return }
        history.remember(search: text)
        saveHistorySoon()
    }

    func forgetSearch(_ text: String) {
        history.forget(search: text)
        saveHistorySoon()
    }

    /// Settings: everything Nook remembered goes, on disk too.
    func clearHistory() {
        history = MusicHistory()
        historySaveTask?.cancel()
        try? FileManager.default.removeItem(at: Self.historyURL)
    }

    /// Several changes in a row are one write, off the main thread.
    private func saveHistorySoon() {
        guard keepsHistory else { return }
        historySaveTask?.cancel()
        historySaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, let snapshot = self?.history else { return }
            await Task.detached(priority: .utility) { Self.write(snapshot) }.value
        }
    }

    private nonisolated static func write(_ history: MusicHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    // MARK: From the player

    /// The player's own top lists, and on Spotify the plays Nook did not see (on the phone, before Nook ran).
    func refreshPlayerStats() {
        guard Date().timeIntervalSince(playerStatsLoadedAt) > Self.playerStatsInterval || playerStats.app != searchApp else { return }
        let app = searchApp
        playerStatsLoadedAt = Date()
        switch app {
        case "Spotify":
            guard SpotifySignIn.shared.isSignedIn else {
                playerStats = MusicPlayerStats(app: app, state: .connectSpotify)
                return
            }
            if playerStats.app != app { playerStats = MusicPlayerStats(app: app, state: .loading) }
            Task { @MainActor [weak self] in
                do {
                    let plays = try await SpotifyWebAPI.recentPlays()
                    let top = try await SpotifyWebAPI.top()
                    guard let self else { return }
                    if self.playerStats != top { self.playerStats = top }
                    guard self.keepsHistory else { return }
                    if self.history.merge(imported: plays) { self.saveHistorySoon() }
                    if self.history.recent.tracks.isEmpty {
                        for play in plays { self.history.recent.add(play.track) }
                    }
                } catch {
                    self?.playerStats = MusicPlayerStats(app: app, state: Self.loadState(for: error))
                }
            }
        default:
            // Reading the counts must not start Music.
            guard Self.isRunning(Self.bundleID(of: "Music")) else {
                playerStats = MusicPlayerStats(app: app)
                return
            }
            queue.async { [weak self] in
                let raw = NowPlayingService.runPlayerScript(MusicScriptOutput.libraryTopScript()).text
                let stats = raw.map { MusicScriptOutput.libraryTop($0) } ?? MusicPlayerStats(app: "Music", state: .failed(tr("music.playlists.musicFailed")))
                Task { @MainActor in
                    guard let self, self.playerStats != stats else { return }
                    self.playerStats = stats
                }
            }
        }
    }
}
