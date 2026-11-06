import AppKit
import Foundation

/// Starting something from the Music tab or the brain, without the player coming up: Spotify through its Web API when it
/// is connected, the player's AppleScript otherwise, with the player started hidden and put back when it takes the
/// front anyway (Spotify brings its window forward for `play track`). The track shows in the tab at once; a poll
/// confirms it.
extension NowPlayingService {
    /// How long the tab trusts the track it just started over what the player still reports.
    private static let startGrace: TimeInterval = 4

    nonisolated static func bundleID(of app: String) -> String {
        app == "Spotify" ? "com.spotify.client" : "com.apple.Music"
    }

    /// Plays through `spotify` when that works, else with `script`, which must hold everything it needs inside its own
    /// `tell`. `shown`: the track to show right away.
    func playInBackground(app: String, spotify: SpotifyResponses.PlayTarget?, script: String, shown: MusicTrack? = nil) {
        // Never two players at once.
        if let other = current, other.app != app, other.isPlaying {
            let pause = Self.playerScript("pause", app: other.app)
            queue.async { _ = NowPlayingService.runPlayerScript(pause) }
        }
        if let shown { showStarting(shown, app: app, until: Date().addingTimeInterval(Self.startGrace)) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if app == "Spotify", SpotifySignIn.shared.isSignedIn, let spotify {
                do {
                    try await SpotifyWebAPI.play(spotify)
                    self.afterStart()
                    return
                } catch {
                    // No device awake or no Premium: the app itself can still do it.
                }
            }
            let played = await self.runBehind(app: app, script: script)
            if !played {
                self.clearStarting()
                ToastCenter.shared.error(tr("music.play.failed"), detail: shown?.title)
            }
            self.afterStart()
        }
    }

    private func afterStart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            Task { @MainActor in
                self?.poll()
                self?.refreshUpNext()
            }
        }
    }

    /// Runs `script` in the player, keeping the player out of sight. `false` when the player refused.
    private func runBehind(app: String, script: String) async -> Bool {
        let bundleID = Self.bundleID(of: app)
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let focus = MusicPlayerFocus(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                     playerBundleID: bundleID, wasOutOfSight: running == nil || running?.isHidden == true)
        let front = NSWorkspace.shared.frontmostApplication
        if running == nil { await Self.launchHidden(bundleID: bundleID) }
        // A player that just started may not answer yet: once more after a moment.
        var played = await Self.run(script)
        if !played, running == nil {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            played = await Self.run(script)
        }
        // The player comes up a moment after it was asked, and not always at the same moment.
        for delay: UInt64 in [100, 400, 900] {
            Self.putBack(focus, front: front)
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        Self.putBack(focus, front: front)
        return played
    }

    private static func run(_ script: String) async -> Bool {
        await withCheckedContinuation { continuation in
            libraryQueue.async { continuation.resume(returning: runPlayerScript(script).errorNumber == nil) }
        }
    }

    /// Opens a player hidden, without taking the front, and waits until it is ready to be asked.
    static func launchHidden(bundleID: String) async {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.hides = true
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try? await Task.sleep(nanoseconds: 1_200_000_000)
    }

    private static func putBack(_ focus: MusicPlayerFocus, front: NSRunningApplication?) {
        guard let player = NSRunningApplication.runningApplications(withBundleIdentifier: focus.playerBundleID).first else { return }
        if focus.shouldHide, !player.isHidden { player.hide() }
        guard focus.stoleFront(now: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return }
        if front?.bundleIdentifier == Bundle.main.bundleIdentifier {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            front?.activate()
        }
    }
}
