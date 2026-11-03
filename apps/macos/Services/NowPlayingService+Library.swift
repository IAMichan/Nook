import Foundation
import AppKit

/// Music tab extras: Up Next from Music, playing a track the user clicks, and lyrics stored with a track in Music. Spotify's AppleScript dictionary has no queue or playlists: for Spotify, Up Next comes from its Web
/// API when the user connected it (`SpotifyWebAPI`), and Recent is kept by Nook itself.
extension NowPlayingService {
    /// How many upcoming tracks Up Next shows.
    nonisolated static let upNextLimit = 25

    /// Reloads Up Next: Music's playlist order, or Spotify's own queue when Spotify is connected. Clears it otherwise.
    func refreshUpNext() {
        if current?.app == "Spotify", SpotifySignIn.shared.isSignedIn {
            libraryLoading = true
            Task { @MainActor [weak self] in
                let tracks = try? await SpotifyWebAPI.queue()
                guard let self else { return }
                self.libraryLoading = false
                let parsed = tracks.map { MusicQueue(playlist: "", tracks: Array($0.prefix(NowPlayingService.upNextLimit))) }
                if self.upNext != parsed { self.upNext = parsed }
            }
            return
        }
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

    /// Plays a track from Up Next (`fromQueue`), Recent or a search. `app`: the player it came from, when no player is
    /// playing yet (a search the brain did); otherwise the player that is playing.
    func play(_ track: MusicTrack, fromQueue: Bool, app preferred: String? = nil) {
        guard let app = current?.app ?? NowPlayingService.runningPlayerName() ?? preferred else { return }
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

    func playAndRefresh(_ verb: String, app: String) {
        queue.async { [weak self] in
            _ = NowPlayingService.runPlayerScript("with timeout of 4 seconds\ntell application \"\(app)\" to \(verb)\nend timeout")
            Thread.sleep(forTimeInterval: 0.4)
            Task { @MainActor in
                guard let self else { return }
                self.poll()
                self.refreshUpNext()
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
}
