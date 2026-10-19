import Foundation
import Combine

/// Autocomplete's settings (UserDefaults, one JSON value), statistics and writing samples (small files in Application
/// Support/Nook/Autocomplete, readable only by you), its models folder, and the pauses.
@MainActor
final class AutocompleteStore: ObservableObject {
    static let shared = AutocompleteStore()

    @Published var prefs: CompletionPreferences { didSet { if prefs != oldValue { defaults.set(prefs.encoded(), forKey: Self.prefsKey) } } }
    @Published private(set) var stats: CompletionStats
    @Published private(set) var samples: CompletionSamples

    /// Paused until this moment, everywhere or per app.
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var appPausedUntil: [String: Date] = [:]
    /// Off in this app until another app comes to the front (Escape setting).
    var offUntilSwitch: String?
    /// The tab Settings › Autocomplete opens on (the notch's "words today" opens Statistics).
    @Published var settingsTab: AutocompleteSettingsTab = .general

    private let defaults = UserDefaults.standard
    private static let prefsKey = "autocompletePreferences"
    private static let recentEmojiKey = "autocompleteRecentEmoji"

    /// Emoji taken from the picker, last first (without skin tone), so the picker opens with them.
    var recentEmoji: [String] { defaults.stringArray(forKey: Self.recentEmojiKey) ?? [] }

    func recordEmoji(_ character: String) {
        defaults.set(Array(([character] + recentEmoji.filter { $0 != character }).prefix(16)), forKey: Self.recentEmojiKey)
    }
    private var statsSave: Task<Void, Never>?

    static var folder: URL { NookPaths.supportDirectory.appendingPathComponent("Autocomplete", isDirectory: true) }
    static var modelsFolder: URL {
        let folder = Self.folder.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    private init() {
        var prefs = defaults.data(forKey: Self.prefsKey).map(CompletionPreferences.decode) ?? CompletionPreferences()
        // The settings of the first version (on/off, accept key, model file).
        if defaults.object(forKey: Self.prefsKey) == nil {
            prefs.enabled = defaults.bool(forKey: "autocompleteEnabled")
            prefs.modelPath = defaults.string(forKey: "autocompleteModelPath") ?? ""
            if defaults.string(forKey: "autocompleteAcceptKey") == "optionTab" { prefs.acceptWord = .optionTab }
        }
        // 120 ms was the first default; 70 shows a suggestion sooner, and a stale one is stopped by the next key anyway.
        if !defaults.bool(forKey: "autocompleteDelayMigrated") {
            if prefs.delayMilliseconds == 120 { prefs.delayMilliseconds = 70 }
            defaults.set(true, forKey: "autocompleteDelayMigrated")
        }
        // 70 ms was the next default; 40 is the shortest the slider has, and a suggestion taken now brings the next one at once.
        if !defaults.bool(forKey: "autocompleteDelayMigrated40") {
            if prefs.delayMilliseconds == 70 { prefs.delayMilliseconds = 40 }
            defaults.set(true, forKey: "autocompleteDelayMigrated40")
        }
        self.prefs = prefs
        stats = Self.load(CompletionStats.self, "stats.json") ?? CompletionStats()
        samples = Self.load(CompletionSamples.self, "samples.json") ?? CompletionSamples()
    }

    // MARK: Counting and learning

    func recordShown() {
        stats.recordShown()
        saveStatsSoon()
    }

    func recordAccepted(_ text: String, first: Bool, app: String?) {
        stats.recordAccepted(text, first: first, app: app)
        saveStatsSoon()
    }

    func resetStats() {
        stats = CompletionStats()
        save(stats, "stats.json")
    }

    /// Returns true when the samples changed.
    @discardableResult
    func addSample(_ text: String, app: String) -> Bool {
        let before = samples
        samples.add(CompletionPrivacy.sanitize(text), app: app)
        guard samples != before else { return false }
        save(samples, "samples.json")
        return true
    }

    func forgetSamples() {
        samples.removeAll()
        save(samples, "samples.json")
    }

    /// Statistics change with every accepted word: write them at most every few seconds.
    private func saveStatsSoon() {
        guard statsSave == nil else { return }
        statsSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            self.statsSave = nil
            self.save(self.stats, "stats.json")
        }
    }

    // MARK: Pausing

    func isPaused(app bundleID: String?, now: Date = Date()) -> Bool {
        if let pausedUntil, pausedUntil > now { return true }
        guard let bundleID else { return false }
        if offUntilSwitch == bundleID { return true }
        if let until = appPausedUntil[bundleID], until > now { return true }
        return false
    }

    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
    }

    func pause(app bundleID: String, seconds: TimeInterval) {
        appPausedUntil[bundleID] = Date().addingTimeInterval(seconds)
    }

    func resume(app bundleID: String? = nil) {
        if let bundleID { appPausedUntil[bundleID] = nil } else { pausedUntil = nil }
    }

    // MARK: Files

    private func save<T: Encodable>(_ value: T, _ name: String) {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try SafeStorage.write(try encoder.encode(value), to: Self.folder.appendingPathComponent(name))
        } catch {
            Log.storage.error("Autocomplete: \(name, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return SafeStorage.load(type, from: folder.appendingPathComponent(name), decoder: decoder).value
    }
}

/// The tabs of Settings › Autocomplete.
enum AutocompleteSettingsTab: String, CaseIterable, Identifiable {
    case general, apps, style, playground, stats

    var id: String { rawValue }
    var title: String { tr("autocomplete.tab.\(rawValue)") }
}

/// Downloads GGUF models (from the list, or a pasted link) into Nook's models folder, with progress, and checks that what
/// arrived is a GGUF model before it can be used.
@MainActor
final class CompletionDownloads: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = CompletionDownloads()

    @Published private(set) var downloading: CompletionCatalogModel?
    @Published private(set) var progress: Double = 0
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published var error: String?
    /// Bumped when a file arrives or goes, so the lists redraw.
    @Published private(set) var changes = 0

    private var task: URLSessionDownloadTask?
    private var done: ((URL) -> Void)?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func file(for model: CompletionCatalogModel) -> URL { AutocompleteStore.modelsFolder.appendingPathComponent(model.fileName) }

    func isInstalled(_ model: CompletionCatalogModel) -> Bool {
        FileManager.default.fileExists(atPath: file(for: model).path)
    }

    /// "1.2 of 2.5 GB" while downloading.
    var progressText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard expected > 0 else { return formatter.string(fromByteCount: received) }
        return tr("autocomplete.download.progress", formatter.string(fromByteCount: received), formatter.string(fromByteCount: expected))
    }

    func download(_ model: CompletionCatalogModel, then done: @escaping (URL) -> Void) {
        guard downloading == nil else { return }
        downloading = model
        progress = 0
        received = 0
        expected = 0
        error = nil
        self.done = done
        task = session.downloadTask(with: model.url)
        task?.resume()
    }

    func cancel() { task?.cancel() }

    func delete(_ model: CompletionCatalogModel) {
        try? FileManager.default.removeItem(at: file(for: model))
        changes += 1
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            received = totalBytesWritten
            expected = max(totalBytesExpectedToWrite, 0)
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            if fraction - progress >= 0.005 || fraction >= 1 { progress = fraction }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns: check and move it now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let target = MainActor.assumeIsolated { downloading.map { file(for: $0) } }
        guard let target else { return }
        guard (200..<300).contains(status) else {
            return MainActor.assumeIsolated { finish(error: tr("autocomplete.download.http", status)) }
        }
        guard GGUFReader.read(location) != nil else {
            return MainActor.assumeIsolated { finish(error: tr("autocomplete.download.notGGUF")) }
        }
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            MainActor.assumeIsolated {
                let done = self.done
                finish(error: nil)
                done?(target)
            }
        } catch {
            MainActor.assumeIsolated { finish(error: error.localizedDescription) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let cancelled = (error as? URLError)?.code == .cancelled
        MainActor.assumeIsolated { finish(error: cancelled ? nil : error.localizedDescription) }
    }

    private func finish(error: String?) {
        guard downloading != nil else { return }
        downloading = nil
        done = nil
        task = nil
        self.error = error
        changes += 1
    }
}
