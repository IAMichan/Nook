import Foundation

/// A name the Music tab asks for before it changes a playlist.
enum MusicPlaylistPrompt: Identifiable, Equatable {
    /// A new playlist, with a track to put in it straight away.
    case create(adding: MusicTrack?)
    case rename(MusicPlaylist)

    var id: String {
        switch self {
        case .create(let track): return "create|\(track?.id ?? "")"
        case .rename(let playlist): return "rename|\(playlist.id)"
        }
    }
}

/// The Music tab's playlists, in Music through AppleScript and on Spotify through its Web API (Spotify's AppleScript has
/// none): list them, open one to see its tracks, play it or a track in it, and keep it: add a track (the playing one or
/// any track in the tab), take one out, make, rename or delete a playlist. Every change shows at once and goes back to
/// what the player says when it fails.
extension NowPlayingService {
    /// The player whose playlists the tab shows: the playing one, else the one that runs, else Spotify when connected.
    var playlistSourceApp: String? {
        current?.app ?? NowPlayingService.runningPlayerName() ?? (SpotifySignIn.shared.isSignedIn ? "Spotify" : nil)
    }

    /// Playlists the user may add `track` to: those of the player the track plays in, that the user may edit.
    func playlistsAccepting(_ track: MusicTrack) -> [MusicPlaylist] {
        guard let app = playlistsApp, Self.canPlay(track, in: app) else { return [] }
        return playlists.filter(\.editable)
    }

    /// The playing track, as something to add to a playlist.
    var currentTrack: MusicTrack? {
        guard let info = current, !info.trackID.isEmpty else { return nil }
        return MusicTrack(id: info.trackID, title: info.title, artist: info.artist, duration: info.duration,
                          artworkURL: info.artworkURL, album: info.album)
    }

    // MARK: Loading

    /// Reloads the playlists of `playlistSourceApp`. What was there stays on screen while it loads.
    func refreshPlaylists() {
        let app = playlistSourceApp
        if app != playlistsApp {
            playlists = []
            playlistsApp = app
            if playlistDetail?.app != app { playlistDetail = nil }
        }
        switch app {
        case "Spotify":
            guard SpotifySignIn.shared.isSignedIn else {
                playlists = []
                playlistsState = .connectSpotify
                return
            }
            if playlists.isEmpty { playlistsState = .loading }
            Task { @MainActor [weak self] in
                do {
                    let found = try await SpotifyWebAPI.playlists()
                    guard let self, self.playlistsApp == "Spotify" else { return }
                    if self.playlists != found { self.playlists = found }
                    self.playlistsState = .done
                } catch {
                    guard let self, self.playlistsApp == "Spotify" else { return }
                    self.playlistsState = Self.loadState(for: error)
                }
            }
        case "Music":
            if playlists.isEmpty { playlistsState = .loading }
            queue.async { [weak self] in
                let result = NowPlayingService.runPlayerScript(NowPlayingService.playlistsScript, cacheKey: "music.playlists.v2")
                let parsed = result.text.map(MusicScriptOutput.playlists) ?? []
                Task { @MainActor in
                    guard let self, self.playlistsApp == "Music" else { return }
                    if self.playlists != parsed { self.playlists = parsed }
                    self.playlistsState = result.text == nil && result.errorNumber != nil
                        ? .failed(tr("music.playlists.musicFailed")) : .done
                }
            }
        default:
            playlists = []
            playlistsState = .idle
        }
    }

    /// Opens a playlist in the tab and loads its tracks.
    func open(_ playlist: MusicPlaylist) {
        guard let app = playlistsApp else { return }
        playlistDetail = MusicPlaylistDetail(playlist: playlist, app: app)
        reloadPlaylistDetail()
    }

    func closePlaylist() {
        playlistDetail = nil
    }

    /// Reads the open playlist's tracks again; the ones shown stay while it loads.
    func reloadPlaylistDetail() {
        guard let detail = playlistDetail else { return }
        let playlist = detail.playlist
        if detail.tracks.isEmpty { playlistDetail?.state = .loading }
        switch detail.app {
        case "Spotify":
            Task { @MainActor [weak self] in
                do {
                    let tracks = try await SpotifyWebAPI.playlistTracks(playlist)
                    self?.applyDetail(tracks, failure: .done, to: playlist.id)
                } catch {
                    self?.applyDetail(nil, failure: Self.loadState(for: error), to: playlist.id)
                }
            }
        default:
            queue.async { [weak self] in
                let raw = NowPlayingService.runPlayerScript(MusicScriptOutput.playlistTracksScript(playlist.id, limit: SpotifyWebAPI.playlistTrackLimit)).text
                let tracks = raw.map(MusicScriptOutput.tracks)
                Task { @MainActor in self?.applyDetail(tracks, failure: .failed(tr("music.playlists.musicFailed")), to: playlist.id) }
            }
        }
    }

    private func applyDetail(_ tracks: [MusicTrack]?, failure: MusicLoadState, to playlistID: String) {
        guard playlistDetail?.playlist.id == playlistID else { return }
        if let tracks {
            if playlistDetail?.tracks != tracks { playlistDetail?.tracks = tracks }
            playlistDetail?.state = .done
            updateCount(of: playlistID, to: tracks.count)
        } else {
            playlistDetail?.state = failure
        }
    }

    // MARK: Playing

    /// Plays a playlist from the top, or shuffled.
    func play(_ playlist: MusicPlaylist, shuffled: Bool? = nil) {
        guard let app = playlistsApp else { return }
        if app == "Spotify" {
            guard SpotifyResponses.playlistID(playlist.id) != nil else { return }
            let shuffle = shuffled.map { "set shuffling to \($0)\n" } ?? ""
            runAndRefresh("\(shuffle)play track \(MusicScriptOutput.quoted(playlist.id))", app: app)
        } else {
            guard Self.isPersistentID(playlist.id) else { return }
            queue.async { [weak self] in
                _ = NowPlayingService.runPlayerScript(MusicScriptOutput.playPlaylistScript(playlist.id, shuffle: shuffled))
                self?.afterPlaying()
            }
        }
    }

    /// Plays a track of a playlist so the player carries on through that playlist afterwards.
    func play(_ track: MusicTrack, in playlist: MusicPlaylist) {
        guard let app = playlistsApp, Self.canPlay(track, in: app) else { return }
        if app == "Spotify" {
            runAndRefresh("play track \(MusicScriptOutput.quoted(track.id)) in context \(MusicScriptOutput.quoted(playlist.id))", app: app)
        } else {
            queue.async { [weak self] in
                _ = NowPlayingService.runPlayerScript(MusicScriptOutput.playPlaylistScript(playlist.id, track: track.id))
                self?.afterPlaying()
            }
        }
    }

    private func runAndRefresh(_ body: String, app: String) {
        queue.async { [weak self] in
            _ = NowPlayingService.runPlayerScript("with timeout of 6 seconds\ntell application \"\(app)\"\n\(body)\nend tell\nend timeout")
            self?.afterPlaying()
        }
    }

    private nonisolated func afterPlaying() {
        Thread.sleep(forTimeInterval: 0.4)
        Task { @MainActor [weak self] in
            self?.poll()
            self?.refreshUpNext()
        }
    }

    // MARK: Keeping playlists

    /// Adds a track to the end of a playlist.
    func add(_ track: MusicTrack, to playlist: MusicPlaylist) {
        guard let app = playlistsApp, Self.canPlay(track, in: app), playlist.editable else { return }
        updateCount(of: playlist.id, by: 1)
        if playlistDetail?.playlist.id == playlist.id { playlistDetail?.tracks.append(track) }
        change(app: app, success: tr("music.playlists.added", playlist.name), detail: track.title, reload: playlist.id) {
            try await SpotifyWebAPI.add(track.id, to: playlist)
        } music: {
            MusicScriptOutput.addToPlaylistScript(track: track.id, playlist: playlist.id)
        }
    }

    /// Takes the track at `index` out of the open playlist (out of the playlist only, never out of the library).
    func removeFromOpenPlaylist(at index: Int) {
        guard let detail = playlistDetail, detail.playlist.editable, detail.tracks.indices.contains(index) else { return }
        let track = detail.tracks[index]
        let playlist = detail.playlist
        // Spotify takes out every copy of the track.
        if detail.app == "Spotify" {
            playlistDetail?.tracks.removeAll { $0.id == track.id }
        } else {
            playlistDetail?.tracks.remove(at: index)
        }
        updateCount(of: playlist.id, to: playlistDetail?.tracks.count ?? 0)
        change(app: detail.app, success: tr("music.playlists.removed", playlist.name), detail: track.title, reload: playlist.id) {
            try await SpotifyWebAPI.remove(track.id, from: playlist)
        } music: {
            MusicScriptOutput.removeFromPlaylistScript(track: track.id, position: index + 1, playlist: playlist.id)
        }
    }

    /// Makes a playlist, puts `track` in it when there is one, and opens it.
    func createPlaylist(named rawName: String, adding track: MusicTrack?) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let app = playlistsApp else { return }
        Task { @MainActor [weak self] in
            do {
                let playlist: MusicPlaylist
                if app == "Spotify" {
                    playlist = try await SpotifyWebAPI.createPlaylist(named: name)
                } else {
                    let id = try await Self.runMusic(MusicScriptOutput.createPlaylistScript(name: name))
                    guard Self.isPersistentID(id) else { throw SpotifyWebAPI.Failure.failed(tr("music.playlists.musicFailed")) }
                    playlist = MusicPlaylist(id: id, name: name, trackCount: 0)
                }
                guard let self, self.playlistsApp == app else { return }
                self.playlists.insert(playlist, at: 0)
                ToastCenter.shared.success(tr("music.playlists.created", name))
                self.open(playlist)
                if let track { self.add(track, to: playlist) }
            } catch {
                ToastCenter.shared.error(tr("music.playlists.failed"), detail: Self.message(for: error))
            }
        }
    }

    func rename(_ playlist: MusicPlaylist, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != playlist.name, let app = playlistsApp else { return }
        if let index = playlists.firstIndex(where: { $0.id == playlist.id }) { playlists[index].name = name }
        if playlistDetail?.playlist.id == playlist.id { playlistDetail?.playlist.name = name }
        change(app: app, success: tr("music.playlists.renamed", name), detail: nil, reload: nil) {
            try await SpotifyWebAPI.rename(playlist, to: name)
        } music: {
            MusicScriptOutput.renamePlaylistScript(playlist.id, to: name)
        }
    }

    func delete(_ playlist: MusicPlaylist) {
        guard let app = playlistsApp else { return }
        playlists.removeAll { $0.id == playlist.id }
        if playlistDetail?.playlist.id == playlist.id { playlistDetail = nil }
        change(app: app, success: tr("music.playlists.deleted", playlist.name), detail: nil, reload: nil) {
            try await SpotifyWebAPI.delete(playlist)
        } music: {
            MusicScriptOutput.deletePlaylistScript(playlist.id)
        }
    }

    /// Runs a change in Spotify or Music. The view already shows it; on failure an error toast says why and the
    /// playlists (and the open one) are read again, so the view goes back to what the player holds.
    private func change(app: String, success: String, detail: String?, reload playlistID: String?,
                        spotify: @escaping () async throws -> Void, music: @escaping () -> String) {
        Task { @MainActor [weak self] in
            do {
                if app == "Spotify" {
                    try await spotify()
                } else {
                    _ = try await Self.runMusic(music())
                }
                ToastCenter.shared.success(success, detail: detail)
                // The player's own count and order (Spotify's a moment after the change).
                if let playlistID, self?.playlistDetail?.playlist.id == playlistID {
                    if app == "Spotify" { try? await Task.sleep(nanoseconds: 600_000_000) }
                    self?.reloadPlaylistDetail()
                }
            } catch {
                ToastCenter.shared.error(tr("music.playlists.failed"), detail: Self.message(for: error))
                self?.refreshPlaylists()
                self?.reloadPlaylistDetail()
            }
        }
    }

    // MARK: Helpers

    private func updateCount(of id: String, by delta: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].trackCount = max(0, playlists[index].trackCount + delta)
    }

    private func updateCount(of id: String, to count: Int) {
        guard let index = playlists.firstIndex(where: { $0.id == id }), playlists[index].trackCount != count else { return }
        playlists[index].trackCount = count
    }

    /// Runs a script in Music on the player queue; its text, or an error when Music refused.
    private static func runMusic(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            libraryQueue.async {
                let result = runPlayerScript(script)
                if let text = result.text {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: SpotifyWebAPI.Failure.failed(tr("music.playlists.musicFailed")))
                }
            }
        }
    }

    static func loadState(for error: Error) -> MusicLoadState {
        switch error as? SpotifyWebAPI.Failure {
        case .notSignedIn?: return .connectSpotify
        case .missingScope?: return .reconnectSpotify
        default: return .failed(message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        switch error as? SpotifyWebAPI.Failure {
        case .notSignedIn?: return tr("music.queue.connectSpotify", tr("settings.section.connections"))
        case .missingScope?: return tr("music.playlists.reconnectDetail", tr("settings.section.connections"))
        case .premiumRequired?: return tr("music.playlists.forbidden")
        case .noActiveDevice?: return tr("music.playlists.notFound")
        case .failed(let message)?: return message
        case nil: return error.localizedDescription
        }
    }

    // MARK: Scripts

    /// id/name/track count/smart of each of the user's own playlists (not the library or special ones such as Music
    /// Videos). Records end with ASCII 30, fields with ASCII 31 (see `MusicScriptOutput`).
    nonisolated static let playlistsScript = """
    with timeout of 6 seconds
    tell application "Music"
        set rs to character id 30
        set fs to character id 31
        set out to ""
        repeat with p in (every user playlist whose special kind is none)
            try
                set isSmart to false
                try
                    set isSmart to smart of p
                end try
                set entry to (persistent ID of p) & fs & (name of p) & fs & ((count of tracks of p) as text) & fs & (isSmart as text)
                if out is "" then
                    set out to entry
                else
                    set out to out & rs & entry
                end if
            end try
        end repeat
        return out
    end tell
    end timeout
    """
}
