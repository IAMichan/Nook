import SwiftUI

// A session's conversation, the Mac's `TranscriptConversation` (apps/macos/NotchUI/Pills/TranscriptTimeline.swift) made
// for the phone: your messages in a soft bubble on the right, the agent's answers as text on the left, its work as quiet
// one-line rows in between, and a finished turn folded into "Worked for 1m 3s". A tap opens what a click opens on the Mac.

/// One row of the conversation, as `TranscriptPresentation` lays it out on the Mac.
enum TranscriptRow: Identifiable {
    case user(TimelineEntry)
    case answer(TimelineEntry, isFinal: Bool)
    /// Steps in a row (with an error or a note among them), as one line that opens to the steps.
    case work(id: String, [TimelineEntry])
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
        let work = turn.indices.filter { $0 != 0 && $0 != answer }.map { turn[$0] }
        guard let firstWork = work.first else { return [.user(first), .answer(turn[answer], isFinal: true)] }
        let end = turn.map(\.date).max() ?? first.date
        return [.user(first), .fold(id: firstWork.id, seconds: end > first.date ? end - first.date : nil, rows: group(work, finalID: nil)),
                .answer(turn[answer], isFinal: true)]
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

    /// Steps in a row become one row; answers stand on their own.
    private static func group(_ entries: [TimelineEntry], finalID: String?) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        var steps: [TimelineEntry] = []
        func flush() {
            if let first = steps.first { rows.append(.work(id: first.id, steps)) }
            steps = []
        }
        for entry in entries {
            switch entry.kind {
            case .tool, .change, .notice, .error:
                steps.append(entry)
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

/// The whole conversation: the rows, the folds and groups you opened, and the end in sight while the agent works.
struct TranscriptConversation: View {
    let entries: [TimelineEntry]
    let working: Bool
    /// Tapping an option in the agent's last answer answers it; nil when the session cannot be written to.
    var onChoose: ((String) -> Void)? = nil
    @State private var open: Set<String> = []

    var body: some View {
        let rows = TranscriptRow.rows(entries, working: working)
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(rows) { row in
                self.row(row)
            }
        }
    }

    @ViewBuilder
    private func row(_ row: TranscriptRow) -> some View {
        switch row {
        case .user(let entry):
            TranscriptUserMessage(text: entry.text)
                .padding(.top, Theme.Spacing.lg)
        case .answer(let entry, let isFinal):
            TranscriptReply(text: entry.text, date: Date(timeIntervalSince1970: entry.date), failed: entry.failed, footer: isFinal)
                .padding(.bottom, isFinal ? Theme.Spacing.lg : Theme.Spacing.xxs)
        case .work(let id, let steps):
            work(id: id, steps: steps)
        case .fold(let id, let seconds, let inner):
            let key = "fold:" + id
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                TranscriptFoldLine(text: seconds.map { String(localized: "Worked for \(TranscriptDuration.text($0))") }
                                    ?? String(localized: "Worked"),
                                   open: open.contains(key)) { toggle(key) }
                if open.contains(key) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(inner) { self.flat($0) }
                    }
                    .padding(.bottom, Theme.Spacing.xs)
                }
            }
        case .working(let since):
            TranscriptWorkingLine(since: since)
        case .live(let step):
            if let step {
                let text = TranscriptStepText.parts(step)
                TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.detail ?? ""), label: text.verb, detail: text.detail,
                                   mono: text.mono, live: true)
            } else {
                TranscriptWorkLine(symbol: "sparkles", label: String(localized: "Thinking…"), live: true)
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
        default: EmptyView()
        }
    }

    /// One step as its own line; several as one line ("4 steps") that opens to them, under a thin rule.
    @ViewBuilder
    private func work(id: String, steps: [TimelineEntry]) -> some View {
        if steps.count == 1, let step = steps.first {
            stepLine(step)
        } else {
            let key = "work:" + id
            let failed = steps.contains(where: \.failed) || steps.contains { $0.kind == .error }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                TranscriptWorkLine(symbol: "square.stack.3d.up", label: String(localized: "\(steps.count) steps"),
                                   detail: steps.last.map { TranscriptStepText.parts($0).detail }, failed: failed,
                                   open: open.contains(key)) { toggle(key) }
                if open.contains(key) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        ForEach(steps) { stepLine($0) }
                    }
                    .padding(.leading, Theme.Spacing.lg)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1).padding(.leading, 9) }
                }
            }
        }
    }

    /// "Ran  npm test": what the agent did, then what it did that to; a failed step in coral, a note or an error in full.
    @ViewBuilder
    private func stepLine(_ step: TimelineEntry) -> some View {
        switch step.kind {
        case .error:
            TranscriptWorkLine(symbol: "exclamationmark.circle", label: step.text, failed: true, wraps: true)
        case .notice:
            TranscriptWorkLine(symbol: "info.circle", label: step.text, wraps: true)
        default:
            let text = TranscriptStepText.parts(step)
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.detail ?? ""), label: text.verb, detail: text.detail,
                               mono: text.mono, failed: step.failed)
        }
    }

    private func toggle(_ key: String) {
        withAnimation(Theme.reveal) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }
}

// MARK: Messages

/// What you wrote, the Mac's `TranscriptUserMessage`, in every conversation (an agent's and the Nook chat): a soft
/// bubble on the right. A long message folds to its first lines; a tap opens the whole of it, a long press copies it.
struct TranscriptUserMessage: View {
    let text: String
    @State private var expanded = false

    private var long: Bool {
        text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(verbatim: text)
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.text)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: long && !expanded ? 176 : nil, alignment: .top)
                    .clipped()
                    .mask {
                        if long && !expanded {
                            VStack(spacing: 0) {
                                Rectangle()
                                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                            }
                        } else {
                            Rectangle()
                        }
                    }
                if long {
                    Button(expanded ? String(localized: "Show less") : String(localized: "Show all")) {
                        withAnimation(Theme.reveal) { expanded.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.TextStyle.label)
                    .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(Theme.Spacing.lg)
            .background(Theme.bubble, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous))
            .contextMenu { CopyButton(text: text) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// The answer, the Mac's `TranscriptReply`, in every conversation (an agent's and the Nook chat): formatted text on the
/// left without a bubble, then what came with it (`extras`), and its time under a final answer. A long press copies it.
struct TranscriptReply<Extras: View>: View {
    let text: String
    var date: Date? = nil
    var failed = false
    /// The time under the answer; only the final answer of a turn has it.
    var footer = true
    @ViewBuilder var extras: () -> Extras

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Markdown.text(text)
                .font(Theme.TextStyle.body)
                .foregroundStyle(failed ? Theme.coral : Theme.textStrong)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            extras()
            if footer, let date {
                TranscriptTime(date: date)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu { CopyButton(text: text) }
    }
}

extension TranscriptReply where Extras == EmptyView {
    init(text: String, date: Date? = nil, failed: Bool = false, footer: Bool = true) {
        self.init(text: text, date: date, failed: failed, footer: footer) { EmptyView() }
    }
}

private struct CopyButton: View {
    let text: String

    var body: some View {
        Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
    }
}

/// "14:03" today, "12 Oct 14:03" before.
struct TranscriptTime: View {
    let date: Date

    var body: some View {
        Text(Calendar.current.isDateInToday(date)
             ? date.formatted(date: .omitted, time: .shortened)
             : date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
            .font(Theme.TextStyle.caption)
            .foregroundStyle(Theme.textTertiary)
            .monospacedDigit()
    }
}

// MARK: Work

/// One line of the agent's work, the Mac's `TranscriptWorkLine`: an icon, what it did in muted text, and a chevron when
/// it opens. The line that runs now breathes.
struct TranscriptWorkLine: View {
    let symbol: String
    let label: String
    var detail: String? = nil
    var mono = false
    var failed = false
    var live = false
    /// A note or an error: the whole text over several lines instead of one.
    var wraps = false
    /// Nil: the line does not open.
    var open: Bool? = nil
    var action: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    private var labelText: Text {
        let head = Text(verbatim: label).foregroundStyle(failed && wraps ? Theme.coral.opacity(0.85) : Theme.textSecondary)
        guard let detail, !detail.isEmpty else { return head }
        return head + Text(verbatim: "  ") + Text(verbatim: detail)
            .font(mono ? Theme.TextStyle.code : Theme.TextStyle.detail)
            .foregroundStyle(Theme.textTertiary)
    }

    var body: some View {
        let content = HStack(alignment: wraps ? .firstTextBaseline : .center, spacing: Theme.Spacing.sm) {
            Image(systemName: failed ? "exclamationmark.circle" : symbol)
                .font(Theme.TextStyle.label)
                .foregroundStyle(failed ? Theme.coral.opacity(0.85) : Theme.textTertiary)
                .frame(width: 20)
            labelText
                .lineLimit(wraps ? 6 : 1)
                .truncationMode(.tail)
                .opacity(live && dim ? 0.45 : 1)
            if let open {
                Image(systemName: "chevron.right")
                    .font(Theme.font(10, .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(Theme.TextStyle.detail)
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

/// A finished turn's work, folded, the Mac's `TranscriptFoldLine`: "Worked for 1m 3s ›" over a hairline.
struct TranscriptFoldLine: View {
    let text: String
    let open: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: text)
                Image(systemName: "chevron.right")
                    .font(Theme.font(10, .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .font(Theme.TextStyle.detail)
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
        .font(Theme.TextStyle.detail)
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
        case .other: return (tool.isEmpty ? summary : tool, tool.isEmpty ? "" : summary, false)
        }
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
            case .edit: return "pencil"
            case .read: return "doc.text"
            case .search: return "magnifyingglass"
            case .other: return "wrench.and.screwdriver"
            }
        }
    }
}

// MARK: Floating status

/// What the session is doing, floating over the end of the conversation right above the composer
/// shows it: "Working for 12s" while the agent works, "Snoozed" with Wake while it sleeps, and an arrow back to the
/// newest message once you scrolled up. Glass on iOS 26, a material before.
struct FloatingWorkingControl: View {
    var workingSince: Date?
    var working = false
    var snoozed = false
    var onWake: (() -> Void)? = nil
    var showScrollToEnd = false
    let onScrollToEnd: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if working || snoozed {
                HStack(spacing: Theme.Spacing.md) {
                    if working {
                        PulseDot(color: Theme.blue, size: 7)
                        if let workingSince {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(verbatim: String(localized: "Working for \(TranscriptDuration.text(max(0, context.date.timeIntervalSince(workingSince))))"))
                                    .monospacedDigit()
                            }
                        } else {
                            Text("Working")
                        }
                    } else {
                        Image(systemName: "moon.zzz.fill").foregroundStyle(Theme.textSecondary)
                        Text("Snoozed")
                        if let onWake {
                            Button(action: onWake) {
                                Text("Wake").font(Theme.TextStyle.label).foregroundStyle(Theme.ink)
                                    .padding(.horizontal, Theme.Spacing.lg)
                                    .frame(height: 28)
                                    .background(Theme.text, in: Capsule())
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
                    Image(systemName: "arrow.down")
                        .font(Theme.font(14, .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .floatingGlass(Circle())
                }
                .buttonStyle(PressFade())
                .accessibilityLabel("Scroll to end")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Theme.reveal, value: working)
        .animation(Theme.reveal, value: snoozed)
        .animation(Theme.reveal, value: showScrollToEnd)
        .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Liquid Glass where the system has it, a dark material with a faint edge before.
    @ViewBuilder
    func floatingGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Theme.text.opacity(0.08), lineWidth: 1))
        }
    }
}
