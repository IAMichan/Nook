import Foundation
import Combine
import CryptoKit

/// Autocomplete's settings (UserDefaults, one JSON value), statistics, writing samples and turned-down phrases (small files
/// in Application Support/Nook/Autocomplete, readable only by you; the samples and phrases encrypted, see `CompletionSealing`),
/// its models folder, and the pauses.
@MainActor
final class AutocompleteStore: ObservableObject {
    static let shared = AutocompleteStore()

    @Published var prefs: CompletionPreferences { didSet { if prefs != oldValue { defaults.set(prefs.encoded(), forKey: Self.prefsKey) } } }
    @Published private(set) var stats: CompletionStats
    @Published private(set) var samples: CompletionSamples
    /// Learned phrases turned down with Escape (see `CompletionPhrases.rejectionKey`) → how often.
    @Published private(set) var phraseRejections: [String: Int]

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

    /// The files with the user's own words, encrypted on disk (see `CompletionSealing`).
    private static let sealedFiles: Set<String> = ["samples.json", "rejected-phrases.json"]
    /// The key they are sealed with; nil when the Keychain could not give or keep one (they are then written plain, as before).
    private var key: SymmetricKey?
    /// Sealed files this launch cannot open because the Keychain did not give the key: kept as they are, never written over.
    private var locked: Set<String> = []

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
        // Pausing on battery was off at first; every suggestion is a model run on this Mac, so it is on now for everyone who
        // kept the old default. Turning it off again in Settings › Autocomplete sticks.
        if !defaults.bool(forKey: "autocompleteBatteryPauseMigrated") {
            prefs.pauseOnBattery = true
            defaults.set(true, forKey: "autocompleteBatteryPauseMigrated")
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
        // 40 ms was the next default; now the model starts on the key itself while the field is read, so there is nothing to
        // wait for.
        if !defaults.bool(forKey: "autocompleteDelayMigrated0") {
            if prefs.delayMilliseconds == 40 { prefs.delayMilliseconds = 0 }
            defaults.set(true, forKey: "autocompleteDelayMigrated0")
        }
        self.prefs = prefs
        let key = Self.sealingKey()
        var locked: Set<String> = []
        var plain: Set<String> = []
        stats = Self.load(CompletionStats.self, "stats.json", key: nil, locked: &locked, plain: &plain) ?? CompletionStats()
        samples = Self.load(CompletionSamples.self, "samples.json", key: key, locked: &locked, plain: &plain) ?? CompletionSamples()
        phraseRejections = Self.load([String: Int].self, "rejected-phrases.json", key: key, locked: &locked, plain: &plain) ?? [:]
        self.key = key
        self.locked = locked
        // Written plain by an earlier version: sealed right away, not only at the next change.
        if key != nil {
            if plain.contains("samples.json") { save(samples, "samples.json") }
            if plain.contains("rejected-phrases.json") { save(phraseRejections, "rejected-phrases.json") }
        }
    }

    /// The key from the Keychain vault. A new one is made only when no sealed file exists yet: when the vault could not be
    /// read (access denied this launch), a new key would make the files already sealed unreadable for good.
    private static func sealingKey() -> SymmetricKey? {
        if let stored = SecretStore.read(CompletionSealing.keyAccount) { return CompletionSealing.decode(stored) }
        let anySealed = sealedFiles.contains { name in
            (try? Data(contentsOf: folder.appendingPathComponent(name))).map(CompletionSealing.isSealed) ?? false
        }
        guard !anySealed else {
            Log.storage.error("Autocomplete: the key for the writing samples is not in the Keychain; they stay as they are this launch")
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        return SecretStore.write(CompletionSealing.encode(key), account: CompletionSealing.keyAccount) == errSecSuccess ? key : nil
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
        // Added to a copy: a sample that changes nothing then leaves the published value (and its observers) alone.
        var next = samples
        next.add(CompletionPrivacy.sanitize(text), app: app)
        guard next != samples else { return false }
        samples = next
        save(samples, "samples.json")
        return true
    }

    func forgetSample(_ sample: CompletionSamples.Sample) {
        samples.remove(sample)
        save(samples, "samples.json")
    }

    func forgetSamples() {
        // Asked for: an old file this launch could not open goes too.
        locked.subtract(Self.sealedFiles)
        samples.removeAll()
        save(samples, "samples.json")
        phraseRejections = [:]
        save(phraseRejections, "rejected-phrases.json")
    }

    func rejectPhrase(_ key: String) {
        phraseRejections[key, default: 0] += 1
        save(phraseRejections, "rejected-phrases.json")
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
        guard !locked.contains(name) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(value)
            if Self.sealedFiles.contains(name), let key { data = try CompletionSealing.seal(data, key: key) }
            try SafeStorage.write(data, to: Self.folder.appendingPathComponent(name))
        } catch {
            Log.storage.error("Autocomplete: \(name, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// - Parameters:
    ///   - key: opens a sealed file; nil for a file that is never sealed.
    ///   - locked: gets the name of a sealed file there is no key for (left alone this launch).
    ///   - plain: gets the name of a file to be sealed that was still plain.
    private static func load<T: Decodable>(_ type: T.Type, _ name: String, key: SymmetricKey?, locked: inout Set<String>,
                                           plain: inout Set<String>) -> T? {
        let url = folder.appendingPathComponent(name)
        guard var data = try? Data(contentsOf: url) else { return nil }
        if CompletionSealing.isSealed(data) {
            guard let key else {
                locked.insert(name)
                return nil
            }
            guard let opened = CompletionSealing.open(data, key: key) else {
                // Sealed with another key, or damaged: kept aside, as with any file that cannot be read.
                SafeStorage.preserve(data, for: url)
                Log.storage.error("Autocomplete: \(name, privacy: .public) could not be decrypted; kept aside")
                return nil
            }
            data = opened
        } else if sealedFiles.contains(name) {
            plain.insert(name)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return SafeStorage.decode(type, data: data, original: url, decoder: decoder).value
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
