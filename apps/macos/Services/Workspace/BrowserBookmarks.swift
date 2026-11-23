import Foundation

/// The pages you starred in Nook's browser: the star in the address bar adds or removes the page, an empty tab lists
/// them, and they come first under the address bar when they fit what you type. Newest first. Foundation only, so tests
/// can use it.
final class BrowserBookmarks: @unchecked Sendable {
    struct Bookmark: Codable, Equatable, Identifiable, Sendable {
        var url: String
        var title: String
        var id: String { url }
    }

    static let shared = BrowserBookmarks(file: NookPaths.supportDirectory.appendingPathComponent("browser-bookmarks.json"))
    /// Posted on the main queue after a bookmark was added or removed, so the star and the empty tab update.
    static let changed = Notification.Name("BrowserBookmarks.changed")

    private let file: URL?
    private let lock = NSLock()
    private var items: [Bookmark] = []
    private var loaded = false

    /// `file` nil keeps everything in memory (tests).
    init(file: URL?) {
        self.file = file
    }

    /// Every bookmark, newest first.
    var all: [Bookmark] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return items
    }

    func contains(_ url: URL?) -> Bool {
        guard let url else { return false }
        let key = BrowserHistory.key(url.absoluteString)
        return all.contains { BrowserHistory.key($0.url) == key }
    }

    /// Adds the page, or removes it when it is already there; true when it is a bookmark afterwards.
    @discardableResult
    func toggle(url: URL, title: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return false }
        let key = BrowserHistory.key(url.absoluteString)
        lock.lock()
        loadIfNeeded()
        let had = items.contains { BrowserHistory.key($0.url) == key }
        if had {
            items.removeAll { BrowserHistory.key($0.url) == key }
        } else {
            items.insert(Bookmark(url: url.absoluteString, title: title), at: 0)
        }
        lock.unlock()
        saveAndAnnounce()
        return !had
    }

    func remove(url: String) {
        let key = BrowserHistory.key(url)
        lock.lock()
        loadIfNeeded()
        items.removeAll { BrowserHistory.key($0.url) == key }
        lock.unlock()
        saveAndAnnounce()
    }

    /// The bookmarks that fit what you typed, ranked as the history ranks pages (`BrowserHistory.rank`).
    func suggestions(for input: String, limit: Int = 3, now: Date = Date()) -> [BrowserSuggestion] {
        let entries = all.map { BrowserHistoryEntry(url: $0.url, title: $0.title, visits: 1, lastVisit: now) }
        return BrowserHistory.rank(entries, for: input, limit: limit, now: now).map {
            BrowserSuggestion(url: $0.url, title: $0.title, isBookmark: true)
        }
    }

    /// Bookmarks first, then the visited pages that are not bookmarks, at most `limit` together.
    static func merged(bookmarks: [BrowserSuggestion], history: [BrowserSuggestion], limit: Int) -> [BrowserSuggestion] {
        let starred = Set(bookmarks.map { BrowserHistory.key($0.url) })
        let rest = history.filter { !starred.contains(BrowserHistory.key($0.url)) }
        return Array((bookmarks + rest).prefix(limit))
    }

    // MARK: Storage

    /// Called with the lock held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder().decode([Bookmark].self, from: data) else { return }
        items = list
    }

    private func saveAndAnnounce() {
        if let file {
            lock.lock()
            let list = items
            lock.unlock()
            if let data = try? JSONEncoder().encode(list) {
                try? data.write(to: file, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }
}

/// Where a download is saved: in the Downloads folder under the name the site gave, with " 2", " 3", … before the
/// extension when that name is taken, as Safari does. Foundation only, so tests can use it.
enum BrowserDownloadName {
    static func destination(for suggested: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        // The site's name, without folders of its own (a name like "../x" must not leave the Downloads folder).
        var name = (suggested as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name == "." || name == ".." {
            name = "download"
        } else if name.hasPrefix(".") {
            // Not hidden in the Downloads folder: ".config" becomes "download.config".
            name = "download" + name
        }
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var number = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !exists(candidate) { return candidate }
            number += 1
        }
    }
}
