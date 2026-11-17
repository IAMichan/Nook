import Foundation

// The files a turn changed, for the card under its last answer, as the Mac shows "3 changed files +12 −4" under an
// agent's turn (`TranscriptTurnViews`). Built from the conversation the phone has (`TimelineEntry.Kind.change`, the file
// in `detail`, the patch in `output`). Foundation only, so it is tested on the Mac (NookTests).

enum PhoneTurnChanges {
    /// One changed file of a turn: its path, the lines its patches added and removed, and the patches, newest last.
    struct File: Equatable, Identifiable {
        var path: String
        var added: Int
        var removed: Int
        var patches: [String]

        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
    }

    /// The files each turn changed, keyed by the id of the turn's last answer (where the card goes). A turn runs from
    /// one message of yours to the next; a turn without an answer yet, or without changes, has no entry.
    static func byFinalAnswer(_ entries: [TimelineEntry]) -> [String: [File]] {
        var result: [String: [File]] = [:]
        var files: [File] = []
        var lastAnswer: String?
        func close() {
            if let lastAnswer, !files.isEmpty { result[lastAnswer] = files }
            files = []
            lastAnswer = nil
        }
        for entry in entries {
            switch entry.kind {
            case .user:
                close()
            case .assistant:
                lastAnswer = entry.id
            case .change:
                let path = (entry.detail ?? entry.text).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { continue }
                let counts = lineCounts(entry.output ?? "")
                if let index = files.firstIndex(where: { $0.path == path }) {
                    files[index].added += counts.added
                    files[index].removed += counts.removed
                    if let patch = entry.output { files[index].patches.append(patch) }
                } else {
                    files.append(File(path: path, added: counts.added, removed: counts.removed,
                                      patches: entry.output.map { [$0] } ?? []))
                }
            default:
                continue
            }
        }
        close()
        return result
    }

    /// The lines a unified patch adds and removes, its file headers left out.
    static func lineCounts(_ patch: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++") || line.hasPrefix("---") { continue }
            if line.hasPrefix("+") { added += 1 } else if line.hasPrefix("-") { removed += 1 }
        }
        return (added, removed)
    }
}
