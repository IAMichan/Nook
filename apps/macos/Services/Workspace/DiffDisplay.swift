import Foundation

// How a stacked diff is shown and searched, apart from the views that draw it: which files count as tests, a diff
// without its whitespace-only hunks, the rows of a unified diff side by side, and the matches of a find in it.
// Foundation only, tested in `DiffDisplayTests`.

/// What a diff is read with, chosen in the diff's toolbar and passed on to whatever reads it (git, a turn's edits).
struct DiffReadOptions: Equatable, Hashable, Sendable {
    /// `git diff -w`: changes that only add, remove or move whitespace are left out.
    var ignoreWhitespace = false

    static let standard = DiffReadOptions()

    /// The key of a file's diff, read with these options, in the cache of diffs read before.
    func cacheKey(scope: String, path: String) -> String { scope + "|" + path + (ignoreWhitespace ? "|w" : "") }
}

enum DiffFileFilter {
    /// A test file by its path: a folder named `test`, `tests`, `Tests` or `__tests__`, any part of the path holding
    /// "Tests" (`NookTests/`, `FooTests.swift`), or a name like `x_test.go`, `x.test.ts` or `x.spec.js`.
    static func isTest(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        for folder in parts.dropLast() where ["test", "tests", "Tests", "__tests__"].contains(folder) { return true }
        if parts.contains(where: { $0.contains("Tests") }) { return true }
        return name.contains("_test.") || name.contains(".test.") || name.contains(".spec.")
    }
}

enum UnifiedDiffFilter {
    /// The diff without the hunks that only change whitespace (indentation, trailing spaces, a line split in two); a
    /// file left without hunks goes altogether. For diffs git did not make, where `-w` cannot be asked for (the edits
    /// an agent reported). Lines outside a hunk (headers, notes) stay as they are.
    static func droppingWhitespaceOnlyHunks(_ diff: String) -> String {
        guard !diff.isEmpty else { return diff }
        let lines = diff.components(separatedBy: "\n")
        var out: [String] = []
        // The lines of the file being read: its header, then each hunk kept.
        var header: [String] = []
        var hunks: [[String]] = []
        var hunk: [String]?
        var sawHunk = false

        func closeHunk() {
            guard let current = hunk else { return }
            if !isWhitespaceOnly(current) { hunks.append(current) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            // A file whose every hunk was whitespace is left out; one without hunks (binary, a mode change) stays.
            if !sawHunk || !hunks.isEmpty { out += header + hunks.flatMap { $0 } }
            header = []
            hunks = []
            sawHunk = false
        }

        for line in lines {
            if line.hasPrefix("diff --git ") {
                closeFile()
                header = [line]
            } else if line.hasPrefix("@@") {
                closeHunk()
                hunk = [line]
                sawHunk = true
            } else if hunk != nil {
                hunk?.append(line)
            } else {
                header.append(line)
            }
        }
        closeFile()
        return out.joined(separator: "\n")
    }

    /// True when what a hunk removes and what it adds are the same once every whitespace character is gone.
    static func isWhitespaceOnly(_ hunk: [String]) -> Bool {
        var removed = ""
        var added = ""
        var changes = false
        for line in hunk.dropFirst() {
            if line.hasPrefix("-") {
                removed += line.dropFirst().filter { !$0.isWhitespace }
                changes = true
            } else if line.hasPrefix("+") {
                added += line.dropFirst().filter { !$0.isWhitespace }
                changes = true
            }
        }
        return changes && removed == added
    }
}

/// The rows of a unified diff side by side: the old file on the left, the new on the right. A run of removed lines
/// faces the added lines right after it, a context line stands on both sides, and a hunk header or note spans both.
enum SplitDiff {
    struct Line: Equatable, Sendable {
        /// Index of the row on the left (a removed or context row), nil for an empty cell.
        var left: Int?
        /// Index of the row on the right (an added or context row), nil for an empty cell.
        var right: Int?
        /// Index of a row that spans both sides (a hunk header, a note, a file), with `left` and `right` nil.
        var full: Int?
    }

    static func lines(_ rows: [UnifiedDiff.Row]) -> [Line] {
        var out: [Line] = []
        var index = 0
        while index < rows.count {
            switch rows[index].kind {
            case .context:
                out.append(Line(left: index, right: index))
                index += 1
            case .remove, .add:
                var removedEnd = index
                while removedEnd < rows.count, rows[removedEnd].kind == .remove { removedEnd += 1 }
                var addedEnd = removedEnd
                while addedEnd < rows.count, rows[addedEnd].kind == .add { addedEnd += 1 }
                let removed = Array(index..<removedEnd)
                let added = Array(removedEnd..<addedEnd)
                for offset in 0..<max(removed.count, added.count) {
                    out.append(Line(left: offset < removed.count ? removed[offset] : nil,
                                    right: offset < added.count ? added[offset] : nil))
                }
                index = addedEnd
            case .hunk, .note, .file:
                out.append(Line(full: index))
                index += 1
            }
        }
        return out
    }
}

/// Find in a diff: every occurrence of the words in the code lines of every file, folded or not, in file order.
enum DiffFind {
    struct Match: Equatable, Hashable, Sendable {
        /// The file's path, as the stacked diff names it.
        var path: String
        /// Index of the row in `UnifiedDiff.rows` of that file's diff.
        var row: Int
        /// Which occurrence in that row (0 for the first), for a line that holds the words twice.
        var occurrence: Int
    }

    /// More than this many matches are not counted: the find stays quick in a diff of a generated file.
    static let limit = 5_000

    /// Case and diacritics do not count; only code lines (context, added, removed) are searched.
    static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    static func matches(_ query: String, in files: [(path: String, rows: [UnifiedDiff.Row])]) -> [Match] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var out: [Match] = []
        for file in files {
            for (index, row) in file.rows.enumerated() {
                switch row.kind {
                case .context, .add, .remove: break
                case .hunk, .note, .file: continue
                }
                for occurrence in 0..<occurrences(of: query, in: row.text) {
                    out.append(Match(path: file.path, row: index, occurrence: occurrence))
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    /// How often `query` (already trimmed) occurs in `text`, not overlapping.
    static func occurrences(of query: String, in text: String) -> Int {
        guard !query.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var start = text.startIndex
        while start < text.endIndex, let found = text.range(of: query, options: options, range: start..<text.endIndex) {
            count += 1
            start = found.upperBound
        }
        return count
    }

    /// The scroll id of a row of a file's diff, shared by the row and the find that scrolls to it.
    static func rowID(path: String, row: Int) -> String { path + "#" + String(row) }
}

/// The matches of a find in a stacked diff and which one is selected.
struct DiffFindState: Equatable {
    var state: TimelineSearchResult.State = .idle
    var matches: [DiffFind.Match] = []
    var current: Int?

    var currentMatch: DiffFind.Match? { current.flatMap { matches.indices.contains($0) ? matches[$0] : nil } }

    static func trimmed(_ query: String) -> String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// New matches: the first is selected, or the one selected before when it is still there.
    mutating func update(_ fresh: [DiffFind.Match]) {
        let kept = currentMatch.flatMap { fresh.firstIndex(of: $0) }
        matches = fresh
        state = fresh.isEmpty ? .noResults : .results
        current = fresh.isEmpty ? nil : (kept ?? 0)
    }

    mutating func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        guard let current else { self.current = forward ? 0 : matches.count - 1; return }
        self.current = forward ? (current + 1) % matches.count : (current - 1 + matches.count) % matches.count
    }
}
