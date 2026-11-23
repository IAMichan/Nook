import Foundation

/// The pages you starred in Nook's browser: the star in the address bar adds or removes the page, an empty tab and the
/// bookmarks menu list them, and they come first under the address bar when they fit what you type. A bookmark sits at
/// the top or in one of your folders (⌥⌘B arranges them). Newest first. Foundation only, so tests can use it.
final class BrowserBookmarks: @unchecked Sendable {
    struct Bookmark: Codable, Equatable, Identifiable, Sendable {
        var url: String
        var title: String
        /// The folder it is in; nil at the top.
        var folder: String?
        var id: String { url }
    }

    /// What is saved: the bookmarks, and the folders in your order (also empty ones).
    private struct Library: Codable {
        var bookmarks: [Bookmark] = []
        var folders: [String] = []
    }

    static let shared = BrowserBookmarks(file: NookPaths.supportDirectory.appendingPathComponent("browser-bookmarks.json"))
    /// Posted on the main queue after a bookmark was added or removed, so the star and the empty tab update.
    static let changed = Notification.Name("BrowserBookmarks.changed")

    private let file: URL?
    private let lock = NSLock()
    private var items: [Bookmark] = []
    private var folderNames: [String] = []
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

    /// Your folders, in your order.
    var folders: [String] {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return folderNames
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

    /// Gives a bookmark another name; an empty name shows its address instead.
    func rename(url: String, to title: String) {
        change { library in
            let key = BrowserHistory.key(url)
            for index in library.items.indices where BrowserHistory.key(library.items[index].url) == key {
                library.items[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// Puts a bookmark in a folder, or at the top for nil.
    func move(url: String, to folder: String?) {
        change { library in
            let key = BrowserHistory.key(url)
            for index in library.items.indices where BrowserHistory.key(library.items[index].url) == key {
                library.items[index].folder = folder
            }
        }
    }

    /// Adds a folder under a name not taken yet ("Work", "Work 2", …) and returns that name.
    @discardableResult
    func addFolder(_ name: String) -> String {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var made = ""
        change { library in
            made = Self.freeName(wanted.isEmpty ? "Folder" : wanted, taken: library.folderNames)
            library.folderNames.append(made)
        }
        return made
    }

    /// Gives a folder another name; its bookmarks go along. A name already taken gets a number.
    func renameFolder(_ old: String, to name: String) {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty, wanted != old else { return }
        change { library in
            guard let index = library.folderNames.firstIndex(of: old) else { return }
            let new = Self.freeName(wanted, taken: library.folderNames.filter { $0 != old })
            library.folderNames[index] = new
            for item in library.items.indices where library.items[item].folder == old { library.items[item].folder = new }
        }
    }

    /// Removes a folder; its bookmarks stay, at the top.
    func removeFolder(_ name: String) {
        change { library in
            library.folderNames.removeAll { $0 == name }
            for item in library.items.indices where library.items[item].folder == name { library.items[item].folder = nil }
        }
    }

    /// `name`, or `name 2`, `name 3`, … when it is taken.
    static func freeName(_ name: String, taken: [String]) -> String {
        guard taken.contains(name) else { return name }
        var number = 2
        while taken.contains("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    private func change(_ body: (inout (items: [Bookmark], folderNames: [String])) -> Void) {
        lock.lock()
        loadIfNeeded()
        var library = (items: items, folderNames: folderNames)
        body(&library)
        items = library.items
        folderNames = library.folderNames
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
              let library = try? JSONDecoder().decode(Library.self, from: data) else { return }
        items = library.bookmarks
        // A folder a bookmark names that went missing from the list still shows.
        folderNames = library.folders + Set(library.bookmarks.compactMap(\.folder)).subtracting(library.folders).sorted()
    }

    private func saveAndAnnounce() {
        if let file {
            lock.lock()
            let library = Library(bookmarks: items, folders: folderNames)
            lock.unlock()
            if let data = try? JSONEncoder().encode(library) {
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
