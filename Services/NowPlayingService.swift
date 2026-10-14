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
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty {
            // Ook een gepauzeerd nummer tonen, zodat je het kunt hervatten.
            let script = """
            tell application "Spotify"
                if player state is stopped then return ""
                return (name of current track) & "|||" & (artist of current track) & "|||" & ((player position as integer) as text) & "|||" & ((duration of current track) as text) & "|||" & (artwork url of current track) & "|||" & ((player state is playing) as text)
            end tell
            """
            let result = SystemControl.appleScriptResult(script)
            if result.errorNumber == -1743 { denied = true }
            if let raw = result.text, !raw.isEmpty {
                let parts = raw.components(separatedBy: "|||")
                if parts.count >= 6 {
                    return (NowPlayingInfo(
                        title: parts[0],
                        artist: parts[1],
                        app: "Spotify",
                        position: Int(parts[2]) ?? 0,
                        duration: (Int(parts[3]) ?? 0) / 1000,   // Spotify geeft milliseconden
                        isPlaying: parts[5] == "true",
                        artworkURL: URL(string: parts[4])
                    ), false)
                }
            }
        }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty {
            let script = """
            tell application "Music"
                if player state is stopped then return ""
                return (name of current track) & "|||" & (artist of current track) & "|||" & ((player position as integer) as text) & "|||" & ((duration of current track as integer) as text) & "|||" & ((player state is playing) as text)
            end tell
            """
            let result = SystemControl.appleScriptResult(script)
            if result.errorNumber == -1743 { denied = true }
            if let raw = result.text, !raw.isEmpty {
                let parts = raw.components(separatedBy: "|||")
                if parts.count >= 5 {
                    return (NowPlayingInfo(
                        title: parts[0],
                        artist: parts[1],
                        app: "Music",
                        position: Int(parts[2]) ?? 0,
                        duration: Int(parts[3]) ?? 0,
                        isPlaying: parts[4] == "true",
                        artworkURL: nil
                    ), false)
                }
            }
        }
        return (nil, denied)
    }
}
