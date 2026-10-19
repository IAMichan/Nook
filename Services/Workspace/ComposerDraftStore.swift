import Foundation

/// Keeps what you were typing per session, and the drafts you set aside, across
/// launches. The rules live in `ComposerDrafts` and `PromptStash`; this only reads and writes the file, a moment after
/// the last keystroke.
@MainActor
final class ComposerDraftStore {
    static let shared = ComposerDraftStore()

    private(set) var drafts = ComposerDrafts()
    private(set) var stash = PromptStash()
    private let url: URL
    private var pending: Task<Void, Never>?

    private struct Stored: Codable {
        var drafts: ComposerDrafts?
        var stash: PromptStash?
    }

    init(url: URL = NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("drafts.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            drafts = stored.drafts ?? ComposerDrafts()
            stash = stored.stash ?? PromptStash()
        }
    }

    func draft(for sessionID: String) -> String? { drafts.draft(for: sessionID) }

    func save(sessionID: String, text: String) {
        drafts.save(sessionID: sessionID, text: text, now: Date())
        scheduleWrite()
    }

    func setStash(_ value: PromptStash) {
        stash = value
        scheduleWrite()
    }

    func prune(keeping ids: Set<String>) {
        drafts.pruneUnused(keeping: ids)
        scheduleWrite()
    }

    private func scheduleWrite() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            let stored = Stored(drafts: drafts, stash: stash)
            guard let data = try? JSONEncoder().encode(stored) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
