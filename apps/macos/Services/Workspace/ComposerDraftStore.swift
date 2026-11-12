import Foundation
import Combine

/// Keeps what you were typing per session, and the drafts you set aside, across
/// launches. The rules live in `ComposerDrafts` and `PromptStash`; this only reads and writes the file, a moment after
/// the last keystroke.
@MainActor
final class ComposerDraftStore: ObservableObject {
    static let shared = ComposerDraftStore()

    private(set) var drafts = ComposerDrafts()
    /// The new-session drafts with words in them, for the list's unsent rows. Published only when a row changes (a draft
    /// appears, goes, or its first line changes), so a keystroke in a session's composer redraws nothing.
    @Published private(set) var unsentNewSessions: [UnsentDraft] = []
    /// The new-session draft the box shows now (`NewSessionDraftKey`), so its row reads as the open one.
    @Published var openNewSession: String?
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
        // What cannot be read is kept aside first (`SafeStorage`), so the next write never loses it for good.
        if let stored = SafeStorage.load(Stored.self, from: url).value {
            drafts = stored.drafts ?? ComposerDrafts()
            stash = stored.stash ?? PromptStash()
        }
        unsentNewSessions = drafts.unsentNewSessions()
    }

    func draft(for sessionID: String) -> String? { drafts.draft(for: sessionID) }

    func save(sessionID: String, text: String) {
        drafts.save(sessionID: sessionID, text: text, now: Date())
        if NewSessionDraftKey.place(of: sessionID) != nil { refreshUnsent() }
        scheduleWrite()
    }

    /// Text you set aside: on top of the stash (⌘S in a composer brings it back).
    func pushToStash(_ text: String) {
        guard stash.push(text) else { return }
        scheduleWrite()
    }

    private func refreshUnsent() {
        let rows = drafts.unsentNewSessions()
        // Same rows in the same order: the time alone does not move a row worth a redraw.
        let same = rows.count == unsentNewSessions.count
            && zip(rows, unsentNewSessions).allSatisfy { $0.key == $1.key && $0.preview == $1.preview }
        if !same { unsentNewSessions = rows }
    }

    func setStash(_ value: PromptStash) {
        stash = value
        scheduleWrite()
    }

    func prune(keeping ids: Set<String>) {
        drafts.pruneUnused(keeping: ids)
        refreshUnsent()
        scheduleWrite()
    }

    private func scheduleWrite() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            pending = nil
            write()
        }
    }

    /// Writes a change that is still waiting for its moment right away (on quit), so the last keystrokes are kept.
    func flush() {
        guard let task = pending else { return }
        task.cancel()
        pending = nil
        write()
    }

    private func write() {
        let stored = Stored(drafts: drafts, stash: stash)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? SafeStorage.write(data, to: url)
    }
}
