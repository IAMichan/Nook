import Foundation
import AppKit

struct NowPlayingInfo: Equatable {
    var title: String
    var artist: String
    var app: String
    var position: Int
    var duration: Int
    var isPlaying: Bool
    var artworkURL: URL?
    /// Wanneer `position` is uitgelezen. Daarmee loopt de voortgang tussen twee polls vloeiend door.
    var capturedAt = Date()

    /// Positie in seconden op dit moment, bijgeschat sinds de laatste poll.
    func estimatedPosition(at date: Date) -> Double {
        guard isPlaying else { return Double(position) }
        let estimate = Double(position) + max(0, date.timeIntervalSince(capturedAt))
        return duration > 0 ? min(Double(duration), estimate) : estimate
    }

    /// `capturedAt` telt niet mee: anders publiceert een gepauzeerd nummer elke poll een "wijziging".
    static func == (lhs: NowPlayingInfo, rhs: NowPlayingInfo) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.app == rhs.app
            && lhs.position == rhs.position && lhs.duration == rhs.duration
            && lhs.isPlaying == rhs.isPlaying && lhs.artworkURL == rhs.artworkURL
    }
}

/// Leest Spotify en Muziek via AppleScript. De systeembrede Now Playing-API is sinds macOS 15.4 niet meer toegankelijk voor gewone apps.
@MainActor
final class NowPlayingService: ObservableObject {
    enum Command: String {
        case playPause = "playpause"
        case next = "next track"
        case previous = "previous track"
    }

    @Published private(set) var current: NowPlayingInfo?
    /// macOS heeft Nook geen toestemming gegeven om Spotify of Muziek te bedienen.
    @Published private(set) var permissionDenied = false

    private var timer: Timer?
    private let queue = DispatchQueue(label: "nl.imdigital.nook.nowplaying")

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    func control(_ command: Command) {
        let appName = current?.app
        // Direct laten zien wat er gaat gebeuren; de poll hieronder bevestigt of corrigeert het.
        if command == .playPause, var info = current {
            info.position = Int(info.estimatedPosition(at: Date()))
            info.isPlaying.toggle()
            info.capturedAt = Date()
            current = info
        }
        queue.async { [weak self] in
            let target = appName ?? NowPlayingService.runningPlayerName()
            if let target {
                _ = SystemControl.appleScript("tell application \"\(target)\" to \(command.rawValue)")
            }
            Thread.sleep(forTimeInterval: 0.4)
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        queue.async { [weak self] in
            let (info, denied) = NowPlayingService.query()
            Task { @MainActor in
                guard let self else { return }
                if self.current != info { self.current = info }
                if self.permissionDenied != denied { self.permissionDenied = denied }
            }
        }
    }

    // MARK: Achtergrondwerk

    private nonisolated static func runningPlayerName() -> String? {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty { return "Spotify" }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty { return "Music" }
        return nil
    }

    private nonisolated static func query() -> (info: NowPlayingInfo?, denied: Bool) {
        var denied = false
        var candidates: [NowPlayingInfo] = []
        for player in players where !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleID).isEmpty {
            let result = SystemControl.appleScriptResult(player.script)
            if result.errorNumber == -1743 { denied = true }
            if let raw = result.text, let info = parse(raw, app: player.name, durationInMilliseconds: player.durationInMilliseconds) {
                candidates.append(info)
            }
        }
        // Speelt er iets, dan dat. Anders het gepauzeerde nummer, zodat je het kunt hervatten.
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

    /// Beide scripts geven: titel|||artiest|||positie|||duur|||artwork|||speelt.
    /// Velden die kunnen ontbreken (radio, lokale bestanden, reclame) staan in een `try`, zodat één leeg veld niet het hele nummer laat verdwijnen.
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
            try
                set art to (artwork url of current track) as text
            end try
            return t & "|||" & a & "|||" & ((p div 1) as text) & "|||" & ((d div 1) as text) & "|||" & art & "|||" & ((player state is playing) as text)
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
            return t & "|||" & a & "|||" & ((p div 1) as text) & "|||" & ((d div 1) as text) & "|||" & "" & "|||" & ((player state is playing) as text)
        end tell
        """),
    ]

    private nonisolated static func parse(_ raw: String, app: String, durationInMilliseconds: Bool) -> NowPlayingInfo? {
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }
        // Een titel kan zelf "|||" bevatten; de laatste vijf velden staan vast.
        let tail = Array(parts.suffix(5))
        let title = parts.dropLast(5).joined(separator: "|||")
        guard !title.isEmpty, title != "missing value" else { return nil }
        let rawDuration = Int(tail[2]) ?? 0
        let duration = durationInMilliseconds ? rawDuration / 1000 : rawDuration
        let position = max(0, Int(tail[1]) ?? 0)
        return NowPlayingInfo(
            title: title,
            artist: tail[0] == "missing value" ? "" : tail[0],
            app: app,
            position: duration > 0 ? min(position, duration) : position,
            duration: duration,
            isPlaying: tail[4] == "true",
            artworkURL: tail[3].hasPrefix("http") ? URL(string: tail[3]) : nil
        )
    }
}
