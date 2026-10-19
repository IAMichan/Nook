import Foundation
import AppKit

/// Music tab extras: Up Next and playlists from Music, playing a track or playlist the user clicks, and lyrics stored with
/// a track in Music. Spotify's AppleScript dictionary has no queue or playlists, so for Spotify only Recent (kept by Nook
/// itself) and playing a recent track by its URI work.
extension NowPlayingService {
    /// How many upcoming tracks Up Next shows.
    nonisolated static let upNextLimit = 25

    /// Reloads Up Next (Music only). Clears it for other players.
    func refreshUpNext() {
        guard current?.app == "Music" else {
            upNext = nil
            return
        }
        libraryLoading = true
        queue.async { [weak self] in
            let raw = NowPlayingService.runPlayerScript(NowPlayingService.upNextScript, cacheKey: "music.upNext").text
            let parsed = raw.flatMap(MusicScriptOutput.queue)
            Task { @MainActor in
                guard let self else { return }
                self.libraryLoading = false
                if self.upNext != parsed { self.upNext = parsed }
            }
        }
    }

    /// Loads the user's playlists from Music.
    func refreshPlaylists() {
        guard current?.app == "Music" || NowPlayingService.isRunning("com.apple.Music") else {
            playlists = []
            return
        }
        queue.async { [weak self] in
            let raw = NowPlayingService.runPlayerScript(NowPlayingService.playlistsScript, cacheKey: "music.playlists").text
            let parsed = raw.map(MusicScriptOutput.playlists) ?? []
            Task { @MainActor in
                guard let self, self.playlists != parsed else { return }
                self.playlists = parsed
            }
        }
    }

    /// Plays a track from Up Next (`fromQueue`) or Recent.
    func play(_ track: MusicTrack, fromQueue: Bool) {
        guard let app = current?.app ?? NowPlayingService.runningPlayerName() else { return }
        let verb: String
        if app == "Spotify" {
            guard Self.isSpotifyURI(track.id) else { return }
            verb = "play track \(MusicScriptOutput.quoted(track.id))"
        } else {
            guard Self.isPersistentID(track.id) else { return }
            let container = fromQueue ? "current playlist" : "library playlist 1"
            verb = "play (first track of \(container) whose persistent ID is \(MusicScriptOutput.quoted(track.id)))"
        }
        playAndRefresh(verb, app: app)
    }

    /// Plays a Music playlist from its first track (or shuffled, when shuffle is on in Music).
    func play(_ playlist: MusicPlaylist) {
        guard Self.isPersistentID(playlist.id) else { return }
        playAndRefresh("play (first user playlist whose persistent ID is \(MusicScriptOutput.quoted(playlist.id)))", app: "Music")
    }

    /// Lyrics stored with the current track in Music, or `nil`.
    nonisolated static func playerLyrics(app: String) -> String? {
        guard app == "Music" else { return nil }
        let script = """
        with timeout of 3 seconds
        tell application "Music"
            if player state is stopped then return ""
            try
                return (lyrics of current track) as text
            end try
            return ""
        end tell
        end timeout
        """
        guard let text = runPlayerScript(script, cacheKey: "music.lyrics").text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "missing value" else { return nil }
        return text
    }

    private func playAndRefresh(_ verb: String, app: String) {
        queue.async { [weak self] in
            _ = NowPlayingService.runPlayerScript("with timeout of 4 seconds\ntell application \"\(app)\" to \(verb)\nend timeout")
            Thread.sleep(forTimeInterval: 0.4)
            Task { @MainActor in
                guard let self else { return }
                self.poll()
                if app == "Music" { self.refreshUpNext() }
            }
        }
    }

    // MARK: Validation

    /// Music persistent IDs are 16 hexadecimal digits.
    nonisolated static func isPersistentID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.allSatisfy(\.isHexDigit)
    }

    /// `spotify:track:…` or `spotify:episode:…` with a base-62 ID.
    nonisolated static func isSpotifyURI(_ id: String) -> Bool {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "track" || parts[1] == "episode" else { return false }
        return !parts[2].isEmpty && parts[2].count <= 64 && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    nonisolated static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: Scripts

    /// Playlist name, then id/title/artist/duration of each track after the current one. Records end with ASCII 30,
    /// fields with ASCII 31 (see `MusicScriptOutput`). The current track is found by its persistent ID: Music's own
    /// Up Next is not scriptable, so this follows the playlist order (shuffle reorders it in Music).
    private nonisolated static let upNextScript = """
    with timeout of 5 seconds
    tell application "Music"
        if player state is stopped then return ""
        set rs to character id 30
        set fs to character id 31
        try
            set pl to current playlist
        on error
            return ""
        end try
        set out to (name of pl) as text
        set cid to ""
        try
            set cid to persistent ID of current track
        end try
        set ids to persistent ID of every track of pl
        set n to count of ids
        set idx to 0
        repeat with i from 1 to n
            if item i of ids is cid then
                set idx to i
                exit repeat
            end if
        end repeat
        set lastI to idx + \(upNextLimit)
        if lastI > n then set lastI to n
        if idx < lastI then
            repeat with i from (idx + 1) to lastI
                try
                    set tr to track i of pl
                    set out to out & rs & (persistent ID of tr) & fs & (name of tr) & fs & (artist of tr) & fs & ((duration of tr) as text)
                end try
            end repeat
        end if
        return out
    end tell
    end timeout
    """

    /// id/name/track count of each of the user's own playlists (not the library or special ones such as Music Videos).
    private nonisolated static let playlistsScript = """
    with timeout of 5 seconds
    tell application "Music"
        set rs to character id 30
        set fs to character id 31
        set out to ""
        repeat with p in (every user playlist whose special kind is none)
            try
                set entry to (persistent ID of p) & fs & (name of p) & fs & ((count of tracks of p) as text)
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
