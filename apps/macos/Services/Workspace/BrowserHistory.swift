import Foundation

/// The pages you visited in Nook's browser, so the address bar can finish what you start typing
/// (`BrowserHistory.suggestions`). Only pages you open yourself are kept: pages an agent opens (a dev server it checks, a
/// page it reads) stay out, so they do not crowd your own. Settings › Browser turns it off and clears it.
/// Foundation only, so tests can use it.
struct BrowserHistoryEntry: Codable, Equatable, Sendable {
    var url: String
    var title: String
    var visits: Int
    var lastVisit: Date
}

/// One line under the address bar: a page you visited before.
struct BrowserSuggestion: Equatable, Identifiable, Sendable {
    let url: String
    let title: String
    var id: String { url }

    /// The address as the bar shows it: without `https://` and `www.`, and without a lone trailing slash.
    var shortAddress: String { BrowserHistory.bare(url) }
}

final class BrowserHistory: @unchecked Sendable {
    static let shared = BrowserHistory(file: NookPaths.supportDirectory.appendingPathComponent("browser-history.json"))

    /// Turns keeping visited pages on or off (Settings › Browser); on unless you turned it off.
    static let enabledKey = "browser.history.enabled"
    /// The most pages kept: the ones visited least recently and least often go first.
    static let limit = 5000

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    private let file: URL?
    private let lock = NSLock()
    private var entries: [String: BrowserHistoryEntry] = [:]
    private var loaded = false
    private var saveScheduled = false

    /// `file` nil keeps everything in memory (tests).
    init(file: URL?) {
        self.file = file
    }

    /// How many pages are kept now.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        loadIfNeeded()
        return entries.count
    }

    /// A page finished loading: counts as a visit. Only web addresses; a search result page counts too, so a search you
    /// make often comes back.
    func record(url: URL, title: String, at date: Date = Date()) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return }
        let key = Self.key(url.absoluteString)
        lock.lock()
        loadIfNeeded()
        if var known = entries[key] {
            // A reload or the same page again within a minute is the same visit.
            if date.timeIntervalSince(known.lastVisit) > 60 { known.visits += 1 }
            known.lastVisit = date
            known.url = url.absoluteString
            if !title.isEmpty { known.title = title }
            entries[key] = known
        } else {
            entries[key] = BrowserHistoryEntry(url: url.absoluteString, title: title, visits: 1, lastVisit: date)
        }
        if entries.count > Self.limit { trim() }
        lock.unlock()
        scheduleSave()
    }

    /// The title a page got after it loaded (sites set it with a script).
    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty else { return }
        let key = Self.key(url.absoluteString)
        lock.lock()
        loadIfNeeded()
        let changed = entries[key].map { $0.title != title } ?? false
        if changed { entries[key]?.title = title }
        lock.unlock()
        if changed { scheduleSave() }
    }

    /// Forgets every page.
    func clear() {
        lock.lock()
        entries = [:]
        loaded = true
        lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// Forgets one page (the cross on its line under the address bar).
    func remove(url: String) {
        lock.lock()
        loadIfNeeded()
        entries[Self.key(url)] = nil
        lock.unlock()
        scheduleSave()
    }

    /// The pages that fit what you typed, best first: see `rank`.
    func suggestions(for input: String, limit: Int = 6, now: Date = Date()) -> [BrowserSuggestion] {
        lock.lock()
        loadIfNeeded()
        let all = Array(entries.values)
        lock.unlock()
        return Self.rank(all, for: input, limit: limit, now: now)
    }

    // MARK: Ranking

    /// The pages that fit `input`, best first. Every word must appear in the address or the title. A page whose address
    /// (without `https://` and `www.`) starts with what you typed comes first, then one whose host or path has a part
    /// starting with it, then the rest; within each, pages you visit often and lately come first.
    static func rank(_ entries: [BrowserHistoryEntry], for input: String, limit: Int, now: Date) -> [BrowserSuggestion] {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, limit > 0 else { return [] }
        let bareQuery = bare(query)
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var scored: [(score: Double, entry: BrowserHistoryEntry)] = []
        for entry in entries {
            let address = bare(entry.url).lowercased()
            let title = entry.title.lowercased()
            guard words.allSatisfy({ address.contains($0) || title.contains($0) }) else { continue }
            let tier: Double
            if address.hasPrefix(bareQuery) {
                tier = 3
            } else if address.split(whereSeparator: { "./-_?=&#".contains($0) }).contains(where: { $0.hasPrefix(words[0]) })
                        || title.split(whereSeparator: \.isWhitespace).contains(where: { $0.hasPrefix(words[0]) }) {
                tier = 2
            } else {
                tier = 1
            }
            scored.append((tier * 1000 + frecency(entry, now: now), entry))
        }
        // Equal scores keep a stable order: the shorter address (the site rather than a page deep in it) first.
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.url.count < b.entry.url.count
        }
        var seen = Set<String>()
        var result: [BrowserSuggestion] = []
        for item in scored {
            let short = bare(item.entry.url)
            guard seen.insert(short).inserted else { continue }
            result.append(BrowserSuggestion(url: item.entry.url, title: item.entry.title))
            if result.count == limit { break }
        }
        return result
    }

    /// How much a page matters: its visits, worth less the longer ago the last one was (half after two weeks). Below 1000,
    /// so it only orders pages within a tier.
    static func frecency(_ entry: BrowserHistoryEntry, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(entry.lastVisit) / 86_400)
        let weight = pow(0.5, days / 14)
        return min(999, Double(min(entry.visits, 200)) * 4 * weight)
    }

    /// What to finish the address bar with after `input`: the address of the best page if it starts with what you typed
    /// (`git` → `github.com/`), else nil. Keeps your own capitals.
    static func completion(for input: String, best: BrowserSuggestion?) -> String? {
        guard let best, !input.isEmpty, !input.contains(" ") else { return nil }
        let typed = input.lowercased()
        let full = bare(best.url)
        // Prefer the site itself over a page in it: `git` finishes to `github.com`, not to a repository.
        let host = full.split(separator: "/", maxSplits: 1).first.map(String.init) ?? full
        for candidate in [host, full] where candidate.lowercased().hasPrefix(typed) && candidate.count > typed.count {
            return input + candidate.dropFirst(input.count)
        }
        return nil
    }

    /// An address without `https://`, `http://` and `www.`, and without a lone trailing slash.
    static func bare(_ url: String) -> String {
        var text = url
        for prefix in ["https://", "http://"] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        if text.hasSuffix("/"), text.filter({ $0 == "/" }).count == 1 { text.removeLast() }
        return text
    }

    /// The same page with or without `www.`, `https` or a trailing slash, and without its `#` part, is one entry.
    static func key(_ url: String) -> String {
        var text = bare(url).lowercased()
        if let hash = text.firstIndex(of: "#") { text = String(text[..<hash]) }
        if text.hasSuffix("/") { text.removeLast() }
        return text
    }

    // MARK: Storage

    /// Keeps the pages that matter most when there are too many. Called with the lock held.
    private func trim() {
        let now = Date()
        let kept = entries.sorted { Self.frecency($0.value, now: now) > Self.frecency($1.value, now: now) }
            .prefix(Self.limit * 9 / 10)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// Called with the lock held.
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let file, let data = try? Data(contentsOf: file),
              let list = try? JSONDecoder.history.decode([BrowserHistoryEntry].self, from: data) else { return }
        for entry in list { entries[Self.key(entry.url)] = entry }
    }

    /// Writes a few seconds after a change, so a burst of pages is one write.
    private func scheduleSave() {
        guard file != nil else { return }
        lock.lock()
        let already = saveScheduled
        saveScheduled = true
        lock.unlock()
        guard !already else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in self?.save() }
    }

    /// Writes the pages now.
    func save() {
        guard let file else { return }
        lock.lock()
        saveScheduled = false
        let list = Array(entries.values)
        lock.unlock()
        guard let data = try? JSONEncoder.history.encode(list) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
