import Foundation

/// Stops a page that keeps reloading itself. A dev server (Next.js, Vite) reloads the page with `location.reload()` when
/// its live-reload socket comes back after a pause, or when a build fails; with an agent editing files at the same time
/// that can turn into a page that compiles and reloads over and over. Reloads the page asks for itself are counted per
/// page; past `limit` within `window` seconds the next one is refused until you reload or open a page yourself.
struct BrowserReloadGuard {
    var limit = 5
    var window: TimeInterval = 30
    private var reloads: [Date] = []
    /// Set once the guard stepped in, so the page says why it stopped.
    private(set) var stopped = false

    init(limit: Int = 5, window: TimeInterval = 30) {
        self.limit = limit
        self.window = window
    }

    /// A reload the page asked for itself: true when it may go ahead.
    mutating func pageReloads(at now: Date = Date()) -> Bool {
        if stopped { return false }
        reloads = reloads.filter { now.timeIntervalSince($0) < window }
        guard reloads.count < limit else {
            stopped = true
            return false
        }
        reloads.append(now)
        return true
    }

    /// You reloaded, or a new page opened: counting starts over.
    mutating func reset() {
        reloads = []
        stopped = false
    }
}
