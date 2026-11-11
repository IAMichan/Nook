import Foundation

// The versions of a file while it is open in the side panel: each time its text changes (the agent wrote it again, you
// saved it) the new text is a version. The panel lists them, shows the difference between two as a diff, and restores
// an older one. Foundation only, tested in `SidePanelCoreTests`.

struct ArtifactVersion: Identifiable, Equatable, Sendable {
    /// 1 for the first text seen, one more for each change after it.
    let number: Int
    let date: Date
    let text: String
    var id: Int { number }
}

struct ArtifactHistory: Equatable, Sendable {
    /// The versions kept: the oldest go first when a file is rewritten more often than this.
    static let limit = 30

    private(set) var versions: [ArtifactVersion] = []
    private var counter = 0

    var latest: ArtifactVersion? { versions.last }

    /// Makes `text` a version when it differs from the latest one. True when it is new. The first text seen is version 1.
    @discardableResult
    mutating func record(_ text: String, at date: Date = Date()) -> Bool {
        if let latest, latest.text == text { return false }
        counter += 1
        versions.append(ArtifactVersion(number: counter, date: date, text: text))
        if versions.count > Self.limit { versions.removeFirst(versions.count - Self.limit) }
        return true
    }

    func version(_ number: Int) -> ArtifactVersion? { versions.first { $0.number == number } }

    /// The version before `number`, as the panel compares one with: nil for the oldest kept.
    func previous(of number: Int) -> ArtifactVersion? {
        guard let index = versions.firstIndex(where: { $0.number == number }), index > 0 else { return nil }
        return versions[index - 1]
    }

    /// The lines added and removed from `old` to `new`.
    static func counts(from old: String, to new: String) -> (added: Int, removed: Int) {
        LineDiff.counts(LineDiff.diff(LineDiff.lines(old), LineDiff.lines(new)))
    }

    /// The change from `old` to `new` as a unified diff of `name` (three lines of context), which the diff viewer draws
    /// like any other. Empty when the texts are the same.
    static func unifiedDiff(from old: String, to new: String, name: String, context: Int = 3) -> String {
        let ops = LineDiff.diff(LineDiff.lines(old), LineDiff.lines(new))
        let changed = ops.indices.filter { if case .same = ops[$0] { return false } else { return true } }
        guard !changed.isEmpty else { return "" }

        // Runs of changes, joined when the lines between them fit inside the context of both.
        var groups: [(first: Int, last: Int)] = []
        for index in changed {
            if let group = groups.last, index - group.last <= 2 * context + 1 {
                groups[groups.count - 1].last = index
            } else {
                groups.append((index, index))
            }
        }

        var out = ["diff --git a/\(name) b/\(name)", "--- a/\(name)", "+++ b/\(name)"]
        for group in groups {
            let start = max(0, group.first - context)
            let end = min(ops.count - 1, group.last + context)
            var oldBefore = 0, newBefore = 0
            for op in ops[..<start] {
                switch op {
                case .same: oldBefore += 1; newBefore += 1
                case .remove: oldBefore += 1
                case .add: newBefore += 1
                }
            }
            var oldCount = 0, newCount = 0
            var body: [String] = []
            for op in ops[start...end] {
                switch op {
                case .same(let line): oldCount += 1; newCount += 1; body.append(" " + line)
                case .remove(let line): oldCount += 1; body.append("-" + line)
                case .add(let line): newCount += 1; body.append("+" + line)
                }
            }
            // A side with no lines names the line before the change, as git does.
            let oldStart = oldCount == 0 ? oldBefore : oldBefore + 1
            let newStart = newCount == 0 ? newBefore : newBefore + 1
            out.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            out += body
        }
        return out.joined(separator: "\n") + "\n"
    }
}
