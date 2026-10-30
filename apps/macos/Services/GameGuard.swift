import AppKit

/// While a game covers the screen (Valorant, or any app that declares itself a game), the notch stays out of the way:
/// it takes no clicks and does not open on hover, so a flick of the mouse at the top of the screen never lands on Nook.
@MainActor
final class GameGuard {
    static let shared = GameGuard()

    /// A game is in front and covers a whole screen.
    private(set) var active = false
    /// Called when `active` changes.
    var onChange: ((Bool) -> Void)?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Whether each process is a game, so Launch Services and the bundle are read once per app.
    private var gameProcesses: [pid_t: Bool] = [:]

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    private func refresh() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              isGame(front) else {
            // Another app in front (or Nook itself): nothing to watch.
            timer?.invalidate()
            timer = nil
            set(false)
            return
        }
        set(Self.coversScreen(pid: front.processIdentifier))
        // A game goes fullscreen after it is activated, and leaves it again: look every few seconds while it is in front.
        if timer == nil {
            timer = Timer.scheduledCoalesced(withTimeInterval: 3) { _ in
                Task { @MainActor in GameGuard.shared.refresh() }
            }
        }
    }

    private func set(_ value: Bool) {
        guard value != active else { return }
        active = value
        onChange?(value)
    }

    private func isGame(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        if let known = gameProcesses[pid] { return known }
        let name = (app.localizedName ?? "").lowercased()
        let id = (app.bundleIdentifier ?? "").lowercased()
        var game = ["valorant", "riot"].contains { name.contains($0) || id.contains($0) }
        if !game, let url = app.bundleURL,
           let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String {
            game = category.hasSuffix("-games")
        }
        gameProcesses[pid] = game
        return game
    }

    /// Whether the process has a normal-layer window the size of a screen, which is what fullscreen and borderless
    /// fullscreen look like to the window server. Owner, layer and bounds are readable without screen recording.
    private static func coversScreen(pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map(\.frame)
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == pid,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            // `CGWindow` bounds are in a top-left space; a screen's size is enough to compare.
            if screens.contains(where: { abs($0.width - rect.width) < 2 && abs($0.height - rect.height) < 2 }) { return true }
        }
        return false
    }
}
