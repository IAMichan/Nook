import Foundation

// One hunk of a file's diff as a patch of its own, so a hunk can be accepted (staged) or rejected (taken out of the
// working tree again) without touching the rest of the file: `git apply --cached` and `git apply -R` take it as it is.
// Foundation only, tested in `SidePanelCoreTests`.

enum HunkAction: Equatable, Sendable {
    /// Keep the hunk and stage it.
    case accept
    /// Take the hunk out of the working tree again.
    case reject
}

struct HunkPatch: Equatable, Sendable {
    /// The file's header: `diff --git`, `index`, `---` and `+++`.
    let header: [String]
    /// Each hunk with its `@@` line first, in the file's order.
    let hunks: [[String]]

    /// Splits the diff of one file. A diff of several files reads the first; one without hunks (binary, a mode change)
    /// has none to act on.
    init(diff: String) {
        var lines = diff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var header: [String] = []
        var hunks: [[String]] = []
        var current: [String]?
        var seenFile = false
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if seenFile { break }
                seenFile = true
            }
            if line.hasPrefix("@@") {
                if let current { hunks.append(current) }
                current = [line]
            } else if current != nil {
                current?.append(line)
            } else {
                header.append(line)
            }
        }
        if let current { hunks.append(current) }
        self.header = header
        self.hunks = hunks
    }

    var count: Int { hunks.count }

    /// The patch of one hunk: the file's header and that hunk, ending in a newline as `git apply` needs.
    func patch(hunk index: Int) -> String? {
        guard hunks.indices.contains(index) else { return nil }
        return (header + hunks[index]).joined(separator: "\n") + "\n"
    }

    /// The arguments for `git apply` that do `action` with a patch file.
    static func arguments(for action: HunkAction, patchPath: String) -> [String] {
        switch action {
        case .accept: return ["apply", "--cached", "--whitespace=nowarn", patchPath]
        case .reject: return ["apply", "--reverse", "--whitespace=nowarn", patchPath]
        }
    }
}
