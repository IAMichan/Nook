import Foundation

/// A unified diff (`git diff`, a pull request patch) split into rows for display: line numbers on both sides,
/// hunk headers, and the changed part of a line that was edited rather than replaced.
enum UnifiedDiff {
    enum Kind: Equatable {
        /// A file in a diff of several files.
        case file
        /// "@@ -10,4 +12,6 @@ func name": `text` holds the trailing context (the function or section), if any.
        case hunk
        case context
        case add
        case remove
        /// "new file mode", "Binary files … differ", "\ No newline at end of file" and the like.
        case note
    }

    struct Row: Equatable {
        let kind: Kind
        /// The line without its diff prefix ("+", "-", " ").
        let text: String
        /// The line exactly as in the diff; review comments refer to it.
        let raw: String
        var old: Int?
        var new: Int?
        /// The part of `text` that changed compared with its paired line (UTF-16 offsets), for an edited line.
        var changed: Range<Int>?
    }

    static func rows(_ diff: String) -> [Row] {
        var rows: [Row] = []
        var old: Int?
        var new: Int?
        for raw in diff.components(separatedBy: "\n") {
            if raw.hasPrefix("diff --git ") {
                old = nil; new = nil
                rows.append(Row(kind: .file, text: filePath(raw), raw: raw))
            } else if raw.hasPrefix("@@") {
                let (oldStart, newStart, section) = hunk(raw)
                old = oldStart; new = newStart
                rows.append(Row(kind: .hunk, text: section, raw: raw, old: oldStart, new: newStart))
            } else if let o = old, let n = new {
                if raw.hasPrefix("+") {
                    rows.append(Row(kind: .add, text: String(raw.dropFirst()), raw: raw, new: n)); new = n + 1
                } else if raw.hasPrefix("-") {
                    rows.append(Row(kind: .remove, text: String(raw.dropFirst()), raw: raw, old: o)); old = o + 1
                } else if raw.hasPrefix("\\") {
                    rows.append(Row(kind: .note, text: String(raw.dropFirst()).trimmingCharacters(in: .whitespaces), raw: raw))
                } else {
                    // Context; some tools strip the space of an empty line.
                    rows.append(Row(kind: .context, text: raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw, raw: raw, old: o, new: n))
                    old = o + 1; new = n + 1
                }
            } else if raw.hasPrefix("index ") || raw.hasPrefix("--- ") || raw.hasPrefix("+++ ") || raw.isEmpty {
                // File headers: the file row and the line numbers already say this.
                continue
            } else {
                rows.append(Row(kind: .note, text: raw, raw: raw))
            }
        }
        // A trailing newline of the diff leaves an empty context row behind.
        if let last = rows.last, last.kind == .context, last.raw.isEmpty { rows.removeLast() }
        // A file row only helps when the diff holds more than one file.
        if rows.filter({ $0.kind == .file }).count < 2 { rows.removeAll { $0.kind == .file } }
        markChanges(&rows)
        return rows
    }

    /// "diff --git a/src/x.swift b/src/x.swift" → "src/x.swift".
    static func filePath(_ header: String) -> String {
        if let range = header.range(of: " b/", options: .backwards) { return String(header[range.upperBound...]) }
        return String(header.dropFirst("diff --git ".count))
    }

    /// "@@ -10,4 +12,6 @@ func name" → (10, 12, "func name").
    static func hunk(_ header: String) -> (old: Int, new: Int, section: String) {
        func start(after marker: String) -> Int {
            guard let range = header.range(of: marker) else { return 1 }
            return Int(header[range.upperBound...].prefix { $0.isNumber }) ?? 1
        }
        var section = ""
        if let open = header.range(of: "@@"), let close = header.range(of: "@@", range: open.upperBound..<header.endIndex) {
            section = header[close.upperBound...].trimmingCharacters(in: .whitespaces)
        }
        return (start(after: "@@ -"), start(after: " +"), section)
    }

    /// "@@ -10,4 +12,6 @@ func name" → "@@ -10,4 +12,6 @@".
    static func hunkLabel(_ header: String) -> String {
        guard let open = header.range(of: "@@"),
              let close = header.range(of: "@@", range: open.upperBound..<header.endIndex) else { return header }
        return String(header[..<close.upperBound])
    }

    /// Pairs each run of removed lines with the added lines right after it and marks what changed within each pair,
    /// so an edit to a few words stands out from a rewritten line.
    private static func markChanges(_ rows: inout [Row]) {
        var index = 0
        while index < rows.count {
            guard rows[index].kind == .remove else { index += 1; continue }
            var removedEnd = index
            while removedEnd < rows.count, rows[removedEnd].kind == .remove { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < rows.count, rows[addedEnd].kind == .add { addedEnd += 1 }
            let pairs = min(removedEnd - index, addedEnd - removedEnd)
            for offset in 0..<pairs {
                let (before, after) = changedRanges(rows[index + offset].text, rows[removedEnd + offset].text)
                rows[index + offset].changed = before
                rows[removedEnd + offset].changed = after
            }
            index = addedEnd
        }
    }

    /// The differing middle of two lines after their common prefix and suffix; nil when the lines share too little
    /// for a highlight to help (the whole line is then simply new).
    static func changedRanges(_ a: String, _ b: String) -> (Range<Int>?, Range<Int>?) {
        let x = Array(a.utf16), y = Array(b.utf16)
        var prefix = 0
        while prefix < x.count, prefix < y.count, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < x.count - prefix, suffix < y.count - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        let shared = prefix + suffix
        guard shared > 0, shared * 4 >= min(x.count, y.count) else { return (nil, nil) }
        let before = prefix..<(x.count - suffix)
        let after = prefix..<(y.count - suffix)
        return (before.isEmpty ? nil : before, after.isEmpty ? nil : after)
    }
}
