import Foundation
import Combine

/// Flow's settings, dictionary, history and numbers. Settings in UserDefaults; the rest as small JSON files in
/// Application Support/Nook/Flow, readable only by you, on this Mac only.
@MainActor
final class FlowStore: ObservableObject {
    static let shared = FlowStore()

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "flowEnabled") } }
    @Published var key: FlowKey { didSet { defaults.set(key.rawValue, forKey: "flowKey") } }
    /// Clean the words with Nook's brain before pasting (the brain you chose: on this Mac unless you picked an external one).
    @Published var cleanup: Bool { didSet { defaults.set(cleanup, forKey: "flowCleanup") } }
    /// What you say becomes a structured prompt for an agent (goal, context, steps, constraints, done when).
    @Published var promptMode: Bool { didSet { defaults.set(promptMode, forKey: "flowPromptMode") } }
    /// Paste in this language whatever you speak ("" = as spoken), e.g. "English".
    @Published var translateTo: String { didSet { defaults.set(translateTo, forKey: "flowTranslateTo") } }
    /// Keep a history of what you dictated (to paste again, and for Nook to search).
    @Published var keepHistory: Bool {
        didSet {
            defaults.set(keepHistory, forKey: "flowKeepHistory")
            if !keepHistory { history = []; save(history, "history.json") }
        }
    }
    /// The style per app (bundle id); apps without one get `FlowStyle.suggested`.
    @Published var appStyles: [String: FlowStyle] { didSet { save(appStyles, "styles.json") } }
    @Published var words: [String] = []
    @Published var replacements: [FlowReplacement] = []
    @Published var snippets: [FlowSnippet] = []
    /// Newest first, the last 200.
    @Published private(set) var history: [FlowEntry] = []
    @Published private(set) var stats = FlowStats()

    private let defaults = UserDefaults.standard
    private var lastUnkept: String?

    static var folder: URL { NookPaths.supportDirectory.appendingPathComponent("Flow", isDirectory: true) }

    private struct DictionaryFile: Codable {
        var words: [String]
        var replacements: [FlowReplacement]
        var snippets: [FlowSnippet]
    }

    private init() {
        enabled = defaults.bool(forKey: "flowEnabled")
        key = FlowKey(rawValue: defaults.string(forKey: "flowKey") ?? "") ?? .rightOption
        cleanup = defaults.object(forKey: "flowCleanup") as? Bool ?? true
        promptMode = defaults.bool(forKey: "flowPromptMode")
        translateTo = defaults.string(forKey: "flowTranslateTo") ?? ""
        keepHistory = defaults.object(forKey: "flowKeepHistory") as? Bool ?? true
        appStyles = Self.load([String: FlowStyle].self, "styles.json") ?? [:]
        if let dictionary = Self.load(DictionaryFile.self, "dictionary.json") {
            words = dictionary.words
            replacements = dictionary.replacements
            snippets = dictionary.snippets
        }
        history = Self.load([FlowEntry].self, "history.json") ?? []
        stats = Self.load(FlowStats.self, "stats.json") ?? FlowStats()
    }

    // MARK: Dictionary

    var dictionaryText: String {
        get { FlowDictionaryText.format(words: words, replacements: replacements, snippets: snippets) }
        set {
            let parsed = FlowDictionaryText.parse(newValue)
            words = parsed.words
            replacements = parsed.replacements
            snippets = parsed.snippets
            save(DictionaryFile(words: words, replacements: replacements, snippets: snippets), "dictionary.json")
        }
    }

    func prepare(_ raw: String) -> FlowText.Prepared {
        FlowText.prepare(raw, words: words, replacements: replacements, snippets: snippets)
    }

    func style(for bundleID: String?) -> FlowStyle {
        bundleID.flatMap { appStyles[$0] } ?? FlowStyle.suggested(for: bundleID)
    }

    // MARK: History and numbers

    var lastText: String? { history.first?.text ?? lastUnkept }

    func record(text: String, app: String?, seconds: Double) {
        let count = FlowText.wordCount(text)
        guard count > 0 else { return }
        stats.record(words: count, seconds: seconds, app: app, on: Date())
        save(stats, "stats.json")
        lastUnkept = text
        guard keepHistory else { return }
        history.insert(FlowEntry(date: Date(), text: text, app: app, words: count, seconds: seconds), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        save(history, "history.json")
    }

    func clearHistory() {
        history = []
        lastUnkept = nil
        save(history, "history.json")
    }

    var wordsPerMinute: Int { FlowText.wordsPerMinute(words: stats.totalWords, seconds: stats.totalSeconds) }
    var minutesSaved: Double { FlowText.minutesSaved(words: stats.totalWords, seconds: stats.totalSeconds) }
    var streak: Int { stats.streak(today: Date()) }

    // MARK: Files

    private func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try SafeStorage.write(try encoder.encode(value), to: Self.folder.appendingPathComponent(name))
        } catch {
            Log.storage.error("Flow: \(name, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return SafeStorage.load(type, from: folder.appendingPathComponent(name), decoder: decoder).value
    }
}
