import Foundation
import AppKit

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var app: String
    var album: String = ""
    /// What the player plays this track by: a Music persistent ID or a Spotify URI. Empty if the player does not say.
    var trackID: String = ""
    var position: Int
    var duration: Int
    var isPlaying: Bool
    var artworkURL: URL?
    /// Shuffle is enabled.
    var shuffle: Bool = false
    /// Repeat is enabled (in Music: single track or all).
    var repeating: Bool = false
    /// Player volume, 0–100. `nil` if player does not report it.
    var volume: Int? = nil
    /// Identifies the track (not its playback state): changes when the next track starts.
    var trackKey: String { trackID.isEmpty ? "\(app)|\(artist)|\(title)" : "\(app)|\(trackID)" }

    /// Timestamp when `position` was sampled, allowing smooth interpolation between polls.
    var capturedAt = Date()

    /// Position in seconds right now, interpolated since last poll.
    func estimatedPosition(at date: Date) -> Double {
        guard isPlaying else { return Double(position) }
        let estimate = Double(position) + max(0, date.timeIntervalSince(capturedAt))
        return duration > 0 ? min(Double(duration), estimate) : estimate
    }

    /// `capturedAt` excluded from equality to avoid publishing spurious changes when paused.
    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.app == rhs.app
            && lhs.album == rhs.album && lhs.trackID == rhs.trackID
            && lhs.position == rhs.position && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying && lhs.artworkURL == rhs.artworkURL
            && lhs.shuffle == rhs.shuffle && lhs.repeating == rhs.repeating && lhs.volume == rhs.volume
    }
}

/// Reads Spotify and Music via AppleScript. System-wide Now Playing API is no longer accessible to standard apps since macOS 15.4.
@MainActor
final class NowPlayingService: ObservableObject {
    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    @Published private(set) var current: NowPlayingInfo? {
        didSet {
            // Remember the track that just ended for Recent.
            guard let old = oldValue, old.trackKey != current?.trackKey else { return }
            recent.add(MusicTrack(id: old.trackID, title: old.title, artist: old.artist, duration: old.duration, artworkURL: old.artworkURL))
        }
    }
    /// Tracks played before the current one, this session.
    @Published private(set) var recent = RecentTracks()
    /// Music: what comes next in the playlist it plays from. `nil` until loaded, or for Spotify.
    @Published var upNext: MusicQueue?
    /// Music: the user's playlists.
    @Published var playlists: [MusicPlaylist] = []
    /// A library request (queue, playlists, lyrics) is running.
    @Published var libraryLoading = false
    /// macOS has not granted Nook permission to control Spotify or Music.
    @Published private(set) var permissionDenied = false

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var lastPoll = Date.distantPast
    private var startedAt = Date()
    /// The one queue every Apple Event to the players runs on (also used by `LyricsService`), so the compiled script
    /// cache is never touched from two threads.
    nonisolated static let libraryQueue = DispatchQueue(label: "nl.imdigital.nook.nowplaying")
    var queue: DispatchQueue { Self.libraryQueue }
    /// Increments on local changes (seek, shuffle, volume) so stale inflight polls don't overwrite them.
    private var localGeneration = 0
    /// Pending volume update. Keeps scrubbing to at most one Apple Event in flight.
    private var pendingVolume: Int?
    private var volumeInFlight = false

    func start() {
        startedAt = Date()
        timer?.invalidate()
        // Players announce every track and play/pause change; react to that at once. The timer is only a safety net.
        if observers.isEmpty {
            let center = DistributedNotificationCenter.default()
            for name in ["com.spotify.client.PlaybackStateChanged", "com.apple.Music.playerInfo", "com.apple.iTunes.playerInfo"] {
                observers.append(center.addObserver(forName: NSNotification.Name(name), object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.pollSoon() }
                })
            }
        }
        timer = Timer.scheduledCoalesced(withTimeInterval: 2.0) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Nothing playing: the players' notifications announce a start, so the safety net can be slow. Right after
                // launch it keeps checking every tick until a player answers: a player that was still starting (or a cold
                // first AppleScript run) should not keep the Music tab away for ten seconds.
                let settling = self.current == nil && Date().timeIntervalSince(self.startedAt) < 20
                if self.current?.isPlaying != true, !settling, Date().timeIntervalSince(self.lastPoll) < 10 { return }
                self.poll()
            }
        }
        poll()
    }

    func control(_ command: Command) {
        let appName = current?.app
        // Optimistic update; subsequent poll confirms or corrects.
        if command == .playPause, var info = current {
            info.position = Int(info.estimatedPosition(at: Date()))
            info.isPlaying.toggle()
            info.capturedAt = Date()
            current = info
            localGeneration += 1
        }
        queue.async { [weak self] in
            let target = appName ?? NowPlayingService.runningPlayerName()
            if let target {
                _ = NowPlayingService.runPlayerScript("with timeout of 3 seconds\ntell application \"\(target)\" to \(command.rawValue)\nend timeout")
            }
            Thread.sleep(forTimeInterval: 0.35)
            Task { @MainActor in self?.poll() }
        }
    }

    /// Seeks to a position in the track, in seconds.
    func seek(to seconds: Double) {
        guard var info = current, info.duration > 0 else { return }
        let target = min(max(0, seconds), Double(max(0, info.duration - 1)))
        info.position = Int(target.rounded())
        info.capturedAt = Date()
        current = info
        localGeneration += 1
        send("set player position to \(Int(target.rounded()))", to: info.app, refresh: true)
    }

    /// Toggles shuffle on or off.
    func setShuffle(_ on: Bool) {
        guard var info = current else { return }
        info.shuffle = on
        current = info
        localGeneration += 1
        let verb = info.app == "Music" ? "set shuffle enabled to \(on)" : "set shuffling to \(on)"
        send(verb, to: info.app, refresh: true)
    }

    /// Toggles repeat on or off. Music repeats all tracks.
    func setRepeat(_ on: Bool) {
        guard var info = current else { return }
        info.repeating = on
        current = info
        localGeneration += 1
        let verb = info.app == "Music" ? "set song repeat to \(on ? "all" : "off")" : "set repeating to \(on)"
        send(verb, to: info.app, refresh: true)
    }

    /// Player volume, 0–100. Safe to call frequently during scrubbing.
    func setVolume(_ value: Int) {
        guard var info = current else { return }
        let clamped = min(100, max(0, value))
        guard info.volume != clamped else { return }
        info.volume = clamped
        current = info
        localGeneration += 1
        pendingVolume = clamped
        flushVolume()
    }

    private func flushVolume() {
        guard !volumeInFlight, let volume = pendingVolume, let target = current?.app else { return }
        pendingVolume = nil
        volumeInFlight = true
        queue.async { [weak self] in
            _ = NowPlayingService.runPlayerScript("with timeout of 2 seconds\ntell application \"\(target)\" to set sound volume to \(volume)\nend timeout")
            Thread.sleep(forTimeInterval: 0.06)
            Task { @MainActor in
                guard let self else { return }
                self.volumeInFlight = false
                self.flushVolume()
            }
        }
    }

    /// Dispatches command to player asynchronously. With `refresh`, polls shortly after.
    private func send(_ verb: String, to app: String, refresh: Bool) {
        queue.async { [weak self] in
            _ = NowPlayingService.runPlayerScript("with timeout of 3 seconds\ntell application \"\(app)\" to \(verb)\nend timeout")
            guard refresh else { return }
            Thread.sleep(forTimeInterval: 0.35)
            Task { @MainActor in self?.poll() }
        }
    }

    /// A player just said something changed. Polls right away, a second time shortly after because the
    /// player's scripting state can lag the notification.
    private func pollSoon() {
        poll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            Task { @MainActor in self?.poll() }
        }
    }

    func poll() {
        // Several notifications can arrive together; one Apple Event round trip is enough.
        guard Date().timeIntervalSince(lastPoll) > 0.1 else { return }
        lastPoll = Date()
        let generation = localGeneration
        queue.async { [weak self] in
            let (info, denied) = NowPlayingService.query()
            Task { @MainActor in
                guard let self else { return }
                if self.permissionDenied != denied { self.permissionDenied = denied }
                // Changed in the meantime? Discard stale poll; next poll will be accurate.
                guard generation == self.localGeneration else { return }
                if self.shouldPublish(newInfo: info) {
                    self.current = info
                }
            }
        }
    }

    /// Avoids firing @Published every poll when the same track is playing and `estimatedPosition(at:)` already
    /// interpolates within 1.8 seconds of the polled position.
    private func shouldPublish(newInfo: NowPlayingInfo?) -> Bool {
        guard let old = current, let new = newInfo else {
            return current != newInfo
        }
        guard old.isPlaying, new.isPlaying,
              old.title == new.title, old.artist == new.artist, old.app == new.app, old.trackID == new.trackID, old.album == new.album,
              old.duration == new.duration, old.artworkURL == new.artworkURL,
              old.shuffle == new.shuffle, old.repeating == new.repeating, old.volume == new.volume else {
            return old != new
        }
        let interpolated = old.estimatedPosition(at: new.capturedAt)
        return abs(Double(new.position) - interpolated) > 1.8
    }

    // MARK: Background Processing

    /// Compiled NSAppleScript cache accessed exclusively on `NowPlayingService.queue` so polling never
    /// contends with `SystemControl.scriptQueue` or recompiles AppleScript source every poll.
    nonisolated(unsafe) static var compiledPlayerScripts: [String: NSAppleScript] = [:]

    nonisolated static func runPlayerScript(_ source: String, cacheKey: String? = nil) -> (text: String?, errorNumber: Int?) {
        let script: NSAppleScript?
        if let cacheKey {
            if let existing = compiledPlayerScripts[cacheKey] {
                script = existing
            } else if let created = NSAppleScript(source: source) {
                compiledPlayerScripts[cacheKey] = created
                script = created
            } else {
                script = nil
            }
        } else {
            script = NSAppleScript(source: source)
        }
        guard let script else { return (nil, nil) }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            return (nil, error[NSAppleScript.errorNumber] as? Int)
        }
        return (output.stringValue, nil)
    }

    nonisolated static func runningPlayerName() -> String? {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty { return "Spotify" }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty { return "Music" }
        return nil
    }

    private nonisolated static func query() -> (info: NowPlayingInfo?, denied: Bool) {
        var denied = false
        var candidates: [NowPlayingInfo] = []
        for player in players where !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty {
            let timedScript = "with timeout of 3 seconds\n\(player.script)\nend timeout"
            let result = runPlayerScript(timedScript, cacheKey: player.bundleID)
            if result.errorNumber == -1743 { denied = true }
            if let raw = result.text, let info = parse(raw, app: player.name, durationInMilliseconds: player.durationInMilliseconds) {
                candidates.append(info)
            }
        }
        // If playback is active, use that. Otherwise use paused track so it can be resumed.
        if let playing = candidates.first(where: \.isPlaying) { return (playing, false) }
        if let paused = candidates.first { return (paused, false) }
        return (nil, denied)
    }

    private struct Player {
        let name: String
        let bundleID: String
        let durationInMilliseconds: Bool
        let script: String
    }

    /// Both scripts yield: title|||artist|||position|||duration|||artwork|||playing|||shuffle|||repeat|||volume|||album|||id.
    /// Volume is -1 if player does not report it.
    /// Optional fields (radio streams, local files, ads) are wrapped in `try` so missing values don't fail parsing.
    private nonisolated static let players: [Player] = [
        Player(name: "Spotify", bundleID: "com.spotify.client", durationInMilliseconds: true, script: """
        tell application "Spotify"
            if player state is stopped then return ""
            set t to ""
            set a to ""
            set p to 0
            set d to 0
            set art to ""
            try
                set t to (name of current track) as text
            end try
            try
                set a to (artist of current track) as text
            end try
            try
                set p to (player position) as real
            end try
            try
                set d to (duration of current track) as real
            end try
            set sh to false
            set rp to false
            set v to -1
            try
                set art to (artwork url of current track) as text
            end try
            try
                set sh to shuffling
            end try
            try
                set rp to repeating
            end try
            try
                set v to (sound volume) as integer
            end try
            set al to ""
            set tid to ""
            try
                set al to (album of current track) as text
            end try
            try
                set tid to (id of current track) as text
            end try
            return t & "|||" & a & "|||" & ((p div 1) as text) & "|||" & ((d div 1) as text) & "|||" & art & "|||" & ((player state is playing) as text) & "|||" & (sh as text) & "|||" & (rp as text) & "|||" & (v as text) & "|||" & al & "|||" & tid
        end tell
        """),
        Player(name: "Music", bundleID: "com.apple.Music", durationInMilliseconds: false, script: """
        tell application "Music"
            if player state is stopped then return ""
            set t to ""
            set a to ""
            set p to 0
            set d to 0
            try
                set t to (name of current track) as text
            end try
            try
                set a to (artist of current track) as text
            end try
            try
                set p to (player position) as real
            end try
            try
                set d to (duration of current track) as real
            end try
            if t is "" then
                try
                    set t to (current stream title) as text
                end try
            end if
            set sh to false
            set rp to false
            set v to -1
            try
                set sh to shuffle enabled
            end try
            try
                if song repeat is not off then set rp to true
            end try
            try
                set v to (sound volume) as integer
            end try
            set al to ""
            set tid to ""
            try
                set al to (album of current track) as text
            end try
            try
                set tid to (persistent ID of current track) as text
            end try
            return t & "|||" & a & "|||" & ((p div 1) as text) & "|||" & ((d div 1) as text) & "|||" & "" & "|||" & ((player state is playing) as text) & "|||" & (sh as text) & "|||" & (rp as text) & "|||" & (v as text) & "|||" & al & "|||" & tid
        end tell
        """),
    ]

    private nonisolated static func parse(_ raw: String, app: String, durationInMilliseconds: Bool) -> NowPlayingInfo? {
        let parts = raw.components(separatedBy: "|||")
        // Title itself could contain "|||"; the trailing ten fields have fixed positions.
        let fixed = 10
        guard parts.count >= fixed + 1 else { return nil }
        let tail = Array(parts.suffix(fixed))
        let title = parts.dropLast(fixed).joined(separator: "|||")
        guard !title.isEmpty, title != "missing value" else { return nil }
        let rawDuration = Int(tail[2]) ?? 0
        let duration = durationInMilliseconds ? rawDuration / 1000 : rawDuration
        let position = max(0, Int(tail[1]) ?? 0)
        let rawVolume = Int(tail[7].trimmingCharacters(in: .whitespaces)) ?? -1
        func clean(_ text: String) -> String { text == "missing value" ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return NowPlayingInfo(
            title: title,
            artist: clean(tail[0]),
            app: app,
            album: clean(tail[8]),
            trackID: clean(tail[9]),
            position: duration > 0 ? min(position, duration) : position,
            duration: duration,
            isPlaying: tail[4] == "true",
            artworkURL: tail[3].hasPrefix("http") ? URL(string: tail[3]) : nil,
            shuffle: tail[5] == "true",
            repeating: tail[6] == "true",
            volume: (0...100).contains(rawVolume) ? rawVolume : nil
        )
    }
}
