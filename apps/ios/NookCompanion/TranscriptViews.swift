import SwiftUI

// A session's conversation, the Mac's `TranscriptConversation` (apps/macos/NotchUI/Pills/TranscriptTimeline.swift) made
// for the phone: your messages in a soft bubble on the right, the agent's answers as text on the left, its work as quiet
// one-line rows in between, and a finished turn folded into "Worked for 1m 3s". A tap opens what a click opens on the Mac.

/// One row of the conversation, as `TranscriptPresentation` lays it out on the Mac.
enum TranscriptRow: Identifiable {
    case user(TimelineEntry)
    case answer(TimelineEntry, isFinal: Bool)
    /// Steps in a row, as one line that opens to the steps.
    case work(id: String, [TimelineEntry])
    /// A compaction (a quiet word across the column) or an error (the problem card), in sight also when its turn folds,
    /// as the Mac's `TranscriptNotice`.
    case notice(TimelineEntry)
    /// A finished turn's work, folded under "Worked for …".
    case fold(id: String, seconds: Double?, rows: [TranscriptRow])
    /// Right under your message while the agent works.
    case working(since: Date?)
    /// The step that runs now, or that the agent thinks.
    case live(TimelineEntry?)

    var id: String {
        switch self {
        case .user(let entry): return "user:" + entry.id
        case .answer(let entry, _): return "answer:" + entry.id
        case .work(let id, _): return "work:" + id
        case .notice(let entry): return "notice:" + entry.id
        case .fold(let id, _, _): return "fold:" + id
        case .working: return "working"
        case .live: return "live"
        }
    }

    /// A turn starts at each message of yours. A finished turn shows your message, "Worked for …" and its final
    /// answer; the turn that runs shows how long it goes, the work so far and the step that runs now.
    static func rows(_ entries: [TimelineEntry], working: Bool) -> [TranscriptRow] {
        var turns: [[TimelineEntry]] = []
        for entry in entries {
            if entry.kind == .user || turns.isEmpty { turns.append([entry]) } else { turns[turns.count - 1].append(entry) }
        }
        var rows: [TranscriptRow] = []
        for (index, turn) in turns.enumerated() {
            rows += working && index == turns.count - 1 ? open(turn) : closed(turn)
        }
        return rows
    }

    private static func closed(_ turn: [TimelineEntry]) -> [TranscriptRow] {
        guard let first = turn.first else { return [] }
        let answer = turn.lastIndex { $0.kind == .assistant }
        guard first.kind == .user, let answer else { return group(turn, finalID: answer.map { turn[$0].id }) }
        // Notices and errors stay in sight; the rest of the work folds.
        let work = turn.indices.filter { $0 != 0 && $0 != answer && !turn[$0].isNotice }.map { turn[$0] }
        let notices = turn.filter(\.isNotice).map { TranscriptRow.notice($0) }
        guard let firstWork = work.first else { return [.user(first)] + notices + [.answer(turn[answer], isFinal: true)] }
        let end = turn.map(\.date).max() ?? first.date
        return [.user(first), .fold(id: firstWork.id, seconds: end > first.date ? end - first.date : nil, rows: group(work, finalID: nil))]
            + notices + [.answer(turn[answer], isFinal: true)]
    }

    private static func open(_ turn: [TimelineEntry]) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var work = turn
        if let first = turn.first, first.kind == .user {
            rows.append(.user(first))
            work.removeFirst()
        }
        rows.append(.working(since: turn.first?.kind == .user ? turn.first.map { Date(timeIntervalSince1970: $0.date) } : nil))
        var current: TimelineEntry?
        if let last = work.last, last.kind == .tool {
            current = last
            work.removeLast()
        }
        rows += group(work, finalID: nil)
        rows.append(.live(current))
        return rows
    }

    /// Steps in a row become one row; answers, notices and errors stand on their own.
    private static func group(_ entries: [TimelineEntry], finalID: String?) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var steps: [TimelineEntry] = []
        func flush() {
            if let first = steps.first { rows.append(.work(id: first.id, steps)) }
            steps = []
        }
        for entry in entries {
            switch entry.kind {
            case .tool, .change:
                steps.append(entry)
            case .notice, .error:
                flush()
                rows.append(.notice(entry))
            case .assistant:
                flush()
                rows.append(.answer(entry, isFinal: entry.id == finalID))
            case .user:
                flush()
                rows.append(.user(entry))
            }
        }
        flush()
        return rows
    }
}

extension TimelineEntry {
    /// A compaction or an error: shown on its own, never folded into the work.
    var isNotice: Bool { kind == .notice || kind == .error }
}

/// The whole conversation: the rows, the folds and groups you opened, and the end in sight while the agent works.
struct TranscriptConversation: View {
    let entries: [TimelineEntry]
    let working: Bool
    /// Tapping an option in the agent's last answer answers it; nil when the session cannot be written to.
    var onChoose: ((String) -> Void)? = nil
    @State private var open: Set<String> = []

    var body: some View {
        let rows = TranscriptRow.rows(entries, working: working)
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(rows) { row in
                self.row(row)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: TranscriptRow) -> some View {
        switch row {
        case .user(let entry):
            // Each turn starts as a block of its own, as on the Mac.
            TranscriptUserMessage(text: entry.text)
                .padding(.top, Theme.Spacing.xxl - Theme.Spacing.sm)
                .padding(.bottom, Theme.Spacing.xxs)
        case .answer(let entry, let isFinal):
            TranscriptReply(text: entry.text, date: Date(timeIntervalSince1970: entry.date), failed: entry.failed, footer: isFinal)
                .padding(.bottom, isFinal ? Theme.Spacing.lg : Theme.Spacing.xxs)
        case .work(let id, let steps):
            work(id: id, steps: steps)
        case .notice(let entry):
            TranscriptNotice(entry: entry)
        case .fold(let id, let seconds, let inner):
            let key = "fold:" + id
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                TranscriptFoldLine(text: seconds.map { String(localized: "Worked for \(TranscriptDuration.text($0))") }
                                    ?? String(localized: "Worked"),
                                   open: open.contains(key)) { toggle(key) }
                if open.contains(key) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        ForEach(inner) { self.flat($0) }
                    }
                    .padding(.bottom, Theme.Spacing.xs)
                }
            }
            .padding(.bottom, Theme.Spacing.xxs)
        case .working(let since):
            TranscriptWorkingLine(since: since)
        case .live(let step):
            if let step {
                let text = TranscriptStepText.parts(step)
                TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.detail ?? ""), label: text.verb, detail: text.detail,
                                   mono: text.mono, live: true)
            } else {
                TranscriptWorkLine(symbol: "brain", label: String(localized: "Thinking…"), live: true)
            }
        }
    }

    /// Every row but a fold (a fold holds only these).
    @ViewBuilder
    private func flat(_ row: TranscriptRow) -> some View {
        switch row {
        case .user(let entry): TranscriptUserMessage(text: entry.text)
        case .answer(let entry, let isFinal): TranscriptReply(text: entry.text, date: Date(timeIntervalSince1970: entry.date), failed: entry.failed, footer: isFinal)
        case .work(let id, let steps): work(id: id, steps: steps)
        case .notice(let entry): TranscriptNotice(entry: entry)
        default: EmptyView()
        }
    }

    /// One step as its own line; several as one sentence ("Ran 3 commands and read 2 files") that opens to them, as on
    /// the Mac (`TranscriptWorkGroup`).
    @ViewBuilder
    private func work(id: String, steps: [TimelineEntry]) -> some View {
        if steps.count == 1, let step = steps.first {
            stepLine(step)
        } else {
            let key = "work:" + id
            let tally = ToolTally(steps)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                TranscriptWorkLine(symbol: TranscriptSymbols.symbol(tally), label: tally.sentence, failed: tally.failed,
                                   open: open.contains(key)) { toggle(key) }
                if open.contains(key) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        ForEach(steps) { stepLine($0) }
                    }
                }
            }
        }
    }

    /// "Ran npm test": what the agent did, then what it did that to, as on the Mac.
    private func stepLine(_ step: TimelineEntry) -> some View {
        let text = TranscriptStepText.parts(step)
        return TranscriptWorkLine(symbol: step.kind == .change ? "square.and.pencil" : TranscriptSymbols.symbol(step.detail ?? ""),
                                  label: text.verb, detail: text.detail, mono: text.mono, failed: step.failed)
    }

    private func toggle(_ key: String) {
        withAnimation(Theme.reveal) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }
}

// MARK: Work

// Your messages and the answers are `TranscriptUserMessage` and `TranscriptReply` in MessageViews.swift, shared with
// the Nook chat.

/// One line of the agent's work, the Mac's `TranscriptWorkLine`: an icon in a column of its own, what it did and what it
/// did that to in one quiet sentence, and a chevron when it opens. The line that runs now breathes.
struct TranscriptWorkLine: View {
    let symbol: String
    let label: String
    var detail: String? = nil
    var mono = false
    var failed = false
    var live = false
    /// Nil: the line does not open.
    var open: Bool? = nil
    var action: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    /// The label, then its detail on the same line in the same quiet color, so a long command or path truncates as one
    /// sentence.
    private var labelText: Text {
        let head = Text(verbatim: label).foregroundStyle(Theme.textTertiary)
        guard let detail, !detail.isEmpty else { return head }
        return head + Text(verbatim: " ") + Text(verbatim: detail)
            .font(mono ? Theme.TextStyle.code : Theme.TextStyle.body)
            .foregroundStyle(Theme.textTertiary)
    }

    var body: some View {
        let content = HStack(spacing: Theme.Spacing.sm) {
            Image(icon: failed ? "exclamationmark.circle" : symbol)
                .font(Theme.TextStyle.body)
                .foregroundStyle(failed ? Theme.coral.opacity(0.6) : Theme.textTertiary)
                .frame(width: 24)
            labelText
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(live && dim ? 0.45 : 1)
            if let open {
                Image(icon: "chevron.right")
                    .font(Theme.font(10, .bold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.7))
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            if failed {
                Image(icon: "xmark").font(Theme.font(10, .bold)).foregroundStyle(Theme.coral.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .font(Theme.TextStyle.body)
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onAppear {
            guard live, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
        }

        if let action, open != nil {
            Button(action: action) { content }
                .buttonStyle(PressFade())
                .accessibilityAddTraits(open == true ? .isSelected : [])
        } else {
            content
        }
    }
}

/// Something that happened to the conversation, the Mac's `TranscriptNotice`: a compaction is a quiet word across the
/// column with room around it; an error is the timeline's problem card; any other note from a session Nook runs is a
/// quiet line, as on the Mac.
struct TranscriptNotice: View {
    let entry: TimelineEntry

    var body: some View {
        if entry.kind == .notice, entry.detail != TimelineEntry.compacted {
            TranscriptWorkLine(symbol: "info.circle", label: entry.text)
        } else if entry.kind == .error {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(icon: "exclamationmark.octagon.fill").foregroundStyle(Theme.coral)
                Text(verbatim: entry.text)
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.coral)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .padding(.vertical, Theme.Spacing.xs)
        } else {
            HStack(spacing: Theme.Spacing.sm) {
                Image(icon: "arrow.down.right.and.arrow.up.left")
                Text(verbatim: entry.text).lineLimit(1)
            }
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.md)
            .accessibilityElement(children: .combine)
        }
    }
}

/// A finished turn's work, folded, the Mac's `TranscriptFoldLine`: "Worked for 1m 3s ›" over a hairline.
struct TranscriptFoldLine: View {
    let text: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: text)
                Image(icon: "chevron.right")
                    .font(Theme.font(10, .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(Theme.TextStyle.body)
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, Theme.Spacing.xxs)
            .padding(.bottom, Theme.Spacing.md)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressFade())
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// Right under your message while the agent works, the Mac's `TranscriptWorkingLine`: "Working for 12s", ticking.
struct TranscriptWorkingLine: View {
    let since: Date?

    var body: some View {
        Group {
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: String(localized: "Working for \(TranscriptDuration.text(max(0, context.date.timeIntervalSince(since))))"))
                        .monospacedDigit()
                }
            } else {
                Text("Working")
            }
        }
        .font(Theme.TextStyle.body)
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Theme.Spacing.xxs)
        .padding(.bottom, Theme.Spacing.md)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// "1m 3s": how long a turn took, as the Mac's `AgentPathFormat.duration`.
enum TranscriptDuration {
    static func text(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return total % 60 == 0 ? "\(total / 60)m" : "\(total / 60)m \(total % 60)s" }
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(total / 3600)h" : "\(total / 3600)h \(minutes)m"
    }
}

/// How a step reads, the Mac's `TranscriptStepText`: what the agent did as a verb ("Ran", "Edited"), then what it did
/// that to, instead of the bare name of the tool. A tool the phone does not know keeps its own name.
enum TranscriptStepText {
    static func parts(_ step: TimelineEntry) -> (verb: String, detail: String, mono: Bool) {
        let tool = step.detail ?? ""
        let summary = step.text
        if step.kind == .change { return (String(localized: "Edited"), summary, true) }
        switch tool {
        case "Task", "Agent": return (String(localized: "Delegated"), summary, false)
        case "TodoWrite", "Plan", "update_plan": return (String(localized: "Updated the task list"), "", false)
        case "ExitPlanMode": return (String(localized: "Proposed a plan"), "", false)
        case "WebSearch", "web_search", "google_web_search": return (String(localized: "Searched the web"), summary, false)
        case "WebFetch", "web_fetch": return (String(localized: "Fetched"), summary, true)
        case "Skill": return (String(localized: "Used skill"), summary, true)
        default: break
        }
        let name = tool.lowercased()
        switch ToolKind.of(tool) {
        case .command: return (String(localized: "Ran"), summary, true)
        case .edit: return (["write", "write_file"].contains(name) ? String(localized: "Wrote") : String(localized: "Edited"), summary, true)
        case .read: return (["ls", "list_directory"].contains(name) ? String(localized: "Listed") : String(localized: "Read"), summary, true)
        case .search: return (String(localized: "Searched"), summary, true)
        case .other:
            // An MCP tool by its label ("GitHub › Create issue"), as on the Mac, not its raw name.
            return (tool.isEmpty ? summary : McpToolLabel.label(tool) ?? tool, tool.isEmpty ? "" : summary, false)
        }
    }
}

/// The label of an MCP tool (`mcp__server__tool`) as the Mac's `McpToolName.label` writes it: "GitHub › Create issue".
enum McpToolLabel {
    static func label(_ raw: String) -> String? {
        guard raw.hasPrefix("mcp__") else { return nil }
        let parts = raw.dropFirst(5).components(separatedBy: "__")
        guard parts.count >= 2, let tool = parts.last, !tool.isEmpty else { return nil }
        var server = parts.dropLast().joined(separator: "__")
        if server.hasPrefix("claude_ai_"), server.count > 10 { server.removeFirst(10) }
        guard !server.isEmpty else { return nil }
        return readable(server) + " › " + readable(tool)
    }

    /// "move_file", "move-file" and "moveFile" read as "Move file".
    private static func readable(_ name: String) -> String {
        var words: [String] = []
        var current = ""
        for character in name {
            if "_-./:".contains(character) {
                if !current.isEmpty { words.append(current) }
                current = ""
            } else if character.isUppercase, let last = current.last, last.isLowercase || last.isNumber {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let lowered = words.enumerated().map { index, word in
            word.count > 1 && word == word.uppercased() ? word : (index == 0 ? word.prefix(1).uppercased() + word.dropFirst().lowercased() : word.lowercased())
        }
        return lowered.joined(separator: " ")
    }
}

/// The kind of work a tool does, the Mac's `ToolCategory`.
enum ToolKind {
    case command, edit, read, search, other

    static func of(_ tool: String) -> ToolKind {
        switch tool.lowercased() {
        case "bash", "shell", "run_shell_command", "nook terminal", "killshell", "bashoutput": return .command
        case "edit", "multiedit", "write", "notebookedit", "write_file", "replace", "apply_patch": return .edit
        case "read", "read_file", "read_many_files", "ls", "list_directory", "notebookread": return .read
        case "grep", "glob", "search_file_content", "websearch", "webfetch", "web_search", "web_fetch", "google_web_search": return .search
        default: return .other
        }
    }
}

/// The icon of a step, after the kind of work it does (the Mac's `TranscriptSymbols`).
enum TranscriptSymbols {
    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Task", "Agent": return "person.2"
        case "TodoWrite", "Plan", "update_plan", "ExitPlanMode": return "checklist"
        case "WebSearch", "WebFetch", "web_search", "web_fetch", "google_web_search": return "globe"
        case "Skill": return "sparkles"
        default:
            switch ToolKind.of(tool) {
            case .command: return "terminal"
            case .edit: return "square.and.pencil"
            case .read: return "eye"
            case .search: return "magnifyingglass"
            case .other: return tool.hasPrefix("mcp") ? "puzzlepiece.extension" : "wrench"
            }
        }
    }

    /// One kind of work keeps its own icon; mixed work gets a hammer.
    static func symbol(_ tally: ToolTally) -> String {
        guard tally.parts.count == 1, let kind = tally.parts.first?.kind else { return "hammer" }
        switch kind {
        case .command: return "terminal"
        case .edit: return "square.and.pencil"
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .other: return "wrench"
        }
    }
}

/// What a run of steps did, counted per kind (the Mac's `ToolTally`), and said as the Mac's group line says it: "Ran 3
/// commands and read 2 files", the two most important kinds of work, then how many other actions. Edits count files.
struct ToolTally {
    private(set) var parts: [(kind: ToolKind, count: Int)] = []
    private(set) var failed = false

    init(_ steps: [TimelineEntry]) {
        var counts: [ToolKind: Int] = [:]
        var files: Set<String> = []
        for step in steps {
            if step.failed { failed = true }
            let kind: ToolKind = step.kind == .change ? .edit : ToolKind.of(step.detail ?? "")
            if kind == .edit { files.insert(step.text) } else { counts[kind, default: 0] += 1 }
        }
        if !files.isEmpty { counts[.edit] = files.count }
        let order: [ToolKind] = [.command, .edit, .read, .search, .other]
        parts = order.compactMap { kind in counts[kind].map { (kind, $0) } }
    }

    var sentence: String {
        guard !parts.isEmpty else { return Self.phrase(.other, 0) }
        let named = parts.prefix(2).map { Self.phrase($0.kind, $0.count) }
        let rest = parts.dropFirst(2).reduce(0) { $0 + $1.count }
        let text: String
        if rest > 0 {
            text = String(localized: "\(named[0]), \(named[1]) and \(rest) more actions")
        } else {
            text = named.count == 2 ? String(localized: "\(named[0]) and \(named[1])") : named[0]
        }
        // "changed 2 files" opens a sentence of its own with a capital, as on the Mac.
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func phrase(_ kind: ToolKind, _ count: Int) -> String {
        switch kind {
        case .command: return String(localized: "Ran \(count) commands")
        case .edit: return String(localized: "changed \(count) files")
        case .read: return String(localized: "read \(count) files")
        case .search: return String(localized: "searched \(count) times")
        case .other: return String(localized: "\(count) other actions")
        }
    }
}

// MARK: Floating status

/// What the session is doing, floating over the end of the conversation right above the composer:
/// "Working for 12s" while the agent works, "Snoozed" with Wake while it sleeps, and an arrow back to the
/// newest message once you scrolled up. Glass on iOS 26, a material before.
struct FloatingWorkingControl: View {
    var workingSince: Date?
    var working = false
    /// Something waits on you (an approval, a question): says so while the agent waits.
    var waiting = false
    var snoozed = false
    var onWake: (() -> Void)? = nil
    var showScrollToEnd = false
    let onScrollToEnd: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if working || waiting || snoozed {
                HStack(spacing: Theme.Spacing.md) {
                    if waiting {
                        Image(icon: "exclamationmark.shield.fill").foregroundStyle(Theme.amber)
                        Text("Waiting for you")
                    } else if working {
                        PulseDot(color: Theme.sky, size: 7)
                        if let workingSince {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(verbatim: String(localized: "Working for \(TranscriptDuration.text(max(0, context.date.timeIntervalSince(workingSince))))"))
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Working")
                        }
                    } else {
                        Image(icon: "moon.zzz.fill").foregroundStyle(Theme.textSecondary)
                        Text("Snoozed")
                        if let onWake {
                            Button(action: onWake) {
                                Text("Wake").font(Theme.TextStyle.label).foregroundStyle(Theme.ink)
                                    .padding(.horizontal, Theme.Spacing.lg)
                                    .frame(height: 28)
                                    .background(Theme.paper, in: Capsule())
                            }
                            .buttonStyle(PressFade())
                        }
                    }
                }
                .font(Theme.TextStyle.label)
                .foregroundStyle(Theme.textStrong)
                .padding(.leading, Theme.Spacing.lg)
                .padding(.trailing, snoozed && onWake != nil ? Theme.Spacing.sm : Theme.Spacing.lg)
                .frame(height: 40)
                .floatingGlass(Capsule())
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if showScrollToEnd {
                Button(action: onScrollToEnd) {
                    Image(icon: "arrow.down")
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.paper)
                        .frame(width: 40, height: 40)
                        .floatingGlass(Circle())
                }
                .buttonStyle(PressFade())
                .accessibilityLabel("Scroll to end")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Theme.reveal, value: working)
        .animation(Theme.reveal, value: waiting)
        .animation(Theme.reveal, value: snoozed)
        .animation(Theme.reveal, value: showScrollToEnd)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Liquid Glass where the system has it, a dark material with a faint edge before.
    @ViewBuilder
    /// Before it, t3code's fallback: the surface at 74 % over a blur, an edge of 8 % white and a soft shadow below.
    func floatingGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .background(Theme.surface.opacity(0.74), in: shape)
                .overlay(shape.stroke(Theme.paper.opacity(0.08), lineWidth: 1))
                .shadow(color: Theme.notch.opacity(0.22), radius: 14, y: 14)
        }
    }
}
