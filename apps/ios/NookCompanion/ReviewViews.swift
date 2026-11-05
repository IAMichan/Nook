import SwiftUI

/// What a session changed in its folder, to review from the phone: every changed file with
/// its lines added and removed, the patch a tap away, and lines to comment on. A comment goes into the session's composer
/// as a `<review_comment>`, the same block the Mac's review sends, so a review becomes the agent's next instruction.
struct SessionChangesView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    /// Puts a review comment in the session's composer.
    let comment: (String) -> Void
    @State private var open: Set<String> = []
    @State private var loaded = false

    private var files: [DiffFileDigest] { client.diffs[sessionID] ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if files.isEmpty {
                    if loaded {
                        WSEmptyState(symbol: "checkmark.circle", title: String(localized: "No changes"),
                                   message: String(localized: "The session's folder has no changes against its last commit."))
                    } else {
                        ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxxl)
                    }
                } else {
                    DiffTotals(files: files)
                    ForEach(files) { file in
                        DiffFileCard(file: file, open: open.contains(file.path), comment: comment) {
                            withAnimation(Theme.reveal) {
                                if open.contains(file.path) { open.remove(file.path) } else { open.insert(file.path) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .refreshable { await client.loadDiff(sessionID) }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { SheetTitle(title: String(localized: "Changes")) } }
        .screen()
        .task {
            await client.loadDiff(sessionID)
            loaded = true
        }
    }
}

/// "12 files · +120 −8": the whole change at a glance.
private struct DiffTotals: View {
    let files: [DiffFileDigest]

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("\(files.count) files")
                .foregroundStyle(Theme.textSecondary)
            LineCounts(added: files.compactMap(\.added).reduce(0, +), removed: files.compactMap(\.removed).reduce(0, +))
            Spacer(minLength: 0)
        }
        .font(Theme.TextStyle.label)
        .padding(.horizontal, Theme.Spacing.xs)
    }
}

/// "+7 −8" in the diff's own colors.
struct LineCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(verbatim: "+\(added)").foregroundStyle(Theme.mint)
            Text(verbatim: "−\(removed)").foregroundStyle(Theme.coral)
        }
        .font(Theme.TextStyle.code)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// One changed file: its name and folder, its lines, and open, its patch with lines you can pick to comment on.
private struct DiffFileCard: View {
    let file: DiffFileDigest
    let open: Bool
    let comment: (String) -> Void
    let toggle: () -> Void

    private var name: String { (file.path as NSString).lastPathComponent }
    private var folder: String { (file.path as NSString).deletingLastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font(10, .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(verbatim: name).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
                        if !folder.isEmpty {
                            Text(verbatim: folder).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.md)
                    if file.kind != "modified" {
                        Text(verbatim: file.kind).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                    }
                    LineCounts(added: file.added ?? 0, removed: file.removed ?? 0)
                }
                .padding(Theme.Spacing.lg)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
            .accessibilityAddTraits(open ? .isSelected : [])
            if open {
                if let patch = file.patch, !patch.isEmpty {
                    PatchView(path: file.path, patch: patch, comment: comment)
                    if file.truncated {
                        Text("The rest of this file's changes is on your Mac.")
                            .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                            .padding(Theme.Spacing.lg)
                    }
                } else {
                    Text("No patch to show for this file.")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                        .padding(Theme.Spacing.lg)
                }
            }
        }
        // A changed file as the Mac's diff shows it: on `surface`, framed by `line2`.
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .cardBackground(Theme.surface, stroke: Theme.line2, radius: Theme.Radius.card, style: .continuous)
    }
}

/// A file's patch, line by line in its colors: tap a line to pick it, tap another to pick the lines between, then
/// Comment writes what the agent should change there.
private struct PatchView: View {
    let path: String
    let patch: String
    let comment: (String) -> Void
    @State private var first: Int?
    @State private var last: Int?
    @State private var writing = false
    @State private var note = ""

    private var lines: [String] { patch.components(separatedBy: "\n").filter { !$0.hasPrefix("diff --git") && !$0.hasPrefix("index ") } }

    private var picked: ClosedRange<Int>? {
        guard let first else { return nil }
        let end = last ?? first
        return min(first, end)...max(first, end)
    }

    var body: some View {
        let lines = lines
        let numbers = PatchLines.newLineNumbers(lines)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        PatchLine(line: line, number: numbers[index], picked: picked?.contains(index) == true)
                            .onTapGesture { pick(index, line: line) }
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
            .background(Theme.well)
            if let picked {
                HStack(spacing: Theme.Spacing.md) {
                    Text(picked.count == 1 ? String(localized: "1 line") : String(localized: "\(picked.count) lines"))
                        .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                    Button("Clear") { withAnimation(Theme.reveal) { first = nil; last = nil } }
                        .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    NookPrimaryButton(title: String(localized: "Comment"), symbol: "text.bubble") { writing = true }
                }
                .padding(Theme.Spacing.lg)
                .transition(.opacity)
            }
        }
        .alert("Comment for the agent", isPresented: $writing) {
            TextField("What should change here?", text: $note, axis: .vertical)
            Button("Add to message") { add(lines: lines, numbers: numbers) }
            Button("Cancel", role: .cancel) { note = "" }
        } message: {
            Text("It goes into your message to the session, with the lines it is about.")
        }
    }

    /// The first tap picks a line, the second the end of a range, a third starts over.
    private func pick(_ index: Int, line: String) {
        guard !line.hasPrefix("@@") else { return }
        Haptics.tap()
        withAnimation(Theme.reveal) {
            if first == nil || last != nil {
                first = index
                last = nil
            } else if index == first {
                first = nil
            } else {
                last = index
            }
        }
    }

    /// The comment as the Mac's review writes it (`ReviewComments.message`), with the picked code quoted.
    private func add(lines: [String], numbers: [Int?]) {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        note = ""
        guard let picked, !text.isEmpty else { return }
        let code = picked.map { lines[$0] }.joined(separator: "\n> ")
        let line = picked.lazy.compactMap { numbers[$0] }.first.map { " line=\"\($0)\"" } ?? ""
        comment("<review_comment file=\"\(path)\"\(line)>\n> \(code)\n\(text)\n</review_comment>")
        Haptics.success()
        withAnimation(Theme.reveal) { first = nil; last = nil }
    }
}

/// One line of a patch: its number on the new side, and the line in the colors of what happened to it.
private struct PatchLine: View {
    let line: String
    let number: Int?
    let picked: Bool

    private var tint: Color? {
        if line.hasPrefix("@@") { return Theme.blue }
        if line.hasPrefix("+") && !line.hasPrefix("+++") { return Theme.mint }
        if line.hasPrefix("-") && !line.hasPrefix("---") { return Theme.coral }
        return nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(verbatim: number.map(String.init) ?? "")
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 34, alignment: .trailing)
            Text(verbatim: line.isEmpty ? " " : line)
                .foregroundStyle(tint ?? Theme.textStrong)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(Theme.TextStyle.code)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((picked ? Theme.iris.opacity(0.16) : tint.map { $0.opacity(0.07) }) ?? Color.clear)
        .contentShape(Rectangle())
    }
}

/// The new-side line number of each line of a unified diff, as the Mac's `ReviewComments.newLineNumbers`.
enum PatchLines {
    static func newLineNumbers(_ lines: [String]) -> [Int?] {
        var result: [Int?] = []
        var next: Int?
        for line in lines {
            if line.hasPrefix("@@") {
                next = line.range(of: " +").flatMap { Int(line[$0.upperBound...].prefix { $0.isNumber }) }
                result.append(nil)
            } else if let current = next, !line.hasPrefix("-"), !line.hasPrefix("\\") {
                result.append(current)
                next = current + 1
            } else {
                result.append(nil)
            }
        }
        return result
    }
}
