import SwiftUI
import AppKit

/// The whole conversation of a session from the agent's own transcript, laid out as Code lays out a thread (see
/// TranscriptPresentation): your messages in a bubble on the right, the agent's answers as text on the left, its work as
/// quiet one-line rows in between, and a finished turn folded into "Worked for 1m 3s". While the agent works the
/// transcript is read again every couple of seconds; an earlier session is read once.
struct TranscriptConversation: View {
    let path: String
    let author: String
    let accent: Color
    /// The agent is working: keep reading and show that it is busy.
    var working = false
    /// Shown when the transcript gives nothing (yet).
    var fallback: [AgentChatMessage] = []
    var onReply: ((String) -> Void)? = nil
    var footer: String? = nil
    /// Reads the conversation from somewhere else than a transcript file (a session in the cloud); nil when it could not.
    var load: (@Sendable () -> [AgentChatMessage]?)? = nil
    /// How often the conversation is read again while the agent works.
    var interval: UInt64 = 2_000_000_000
    @State private var messages: [AgentChatMessage] = []
    @State private var loaded = false
    /// The session's folder on this Mac, for the files the agent wrote; nil when they are not here (a cloud session).
    var directory: String? = nil
    /// Folds, groups and thoughts you opened.
    @State private var open: Set<String> = []
    /// The panel next to the conversation with what the agent produced; its button sits in the header of the view
    /// that shows the conversation (see SessionOutputsButton), which reads the count from TranscriptOutputCount.
    var outputsOpen: Binding<Bool> = .constant(false)
    @State private var outputSelection: String?
    /// A file the agent read or wrote that you clicked: shown in the side panel, in place of the outputs.
    @State private var preview: String?
    /// How wide the results are: drag the line beside them, double-click it to reset. Remembered, as in a Nook session.
    @AppStorage("nook.agents.outputsWidth") private var outputsWidth = PanelLayout.outputs
    @State private var totalWidth: Double = 0

    private var shown: [AgentChatMessage] { messages.isEmpty ? fallback : messages }

    var body: some View {
        let rows = TranscriptPresentation.rows(shown, working: working)
        // Only the very last answer can still be answered by tapping one of its options.
        let answerable = working ? nil : shown.last(where: { $0.kind == .assistant })?.id
        let outputs = SessionOutputs.collect(shown, directory: directory ?? "").filter { directory != nil || !$0.isFile }
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    // Lazy: a long conversation only lays out what is on screen.
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if shown.isEmpty {
                            Text(loaded || (path.isEmpty && load == nil) ? tr("agents.noMessagesInTranscript") : tr("agents.checking"))
                                .font(NookTheme.font(12.5))
                                .foregroundStyle(NookTheme.textTertiary)
                        }
                        ForEach(rows) { row in
                            self.row(row, answerable: answerable).id(row.id)
                        }
                        if let footer {
                            Text(footer)
                                .font(NookTheme.font(11.5))
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(.top, 4)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Open at the newest message; the transcript loads after the view appears, so also follow it once it arrives.
                .defaultScrollAnchor(.bottom)
                .onChange(of: shown) { _, _ in scrollToEnd(proxy) }
                .onChange(of: loaded) { _, _ in scrollToEnd(proxy) }
                .onAppear {
                    scrollToEnd(proxy)
                    DispatchQueue.main.async { scrollToEnd(proxy) }
                }
            }
            if let preview {
                FilePreviewPanel(path: preview, wide: PanelLayout.wide($outputsWidth)) {
                    withAnimation(.easeInOut(duration: 0.2)) { self.preview = nil }
                }
                .id(preview)
                .resizablePanel(width: $outputsWidth, defaultWidth: PanelLayout.outputs, minimum: PanelLayout.minimumPanel,
                                available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .leading)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if outputsOpen.wrappedValue {
                SessionOutputsPanel(outputs: outputs, selection: $outputSelection, wide: PanelLayout.wide($outputsWidth)) {
                    withAnimation(.easeInOut(duration: 0.2)) { outputsOpen.wrappedValue = false }
                }
                .resizablePanel(width: $outputsWidth, defaultWidth: PanelLayout.outputs, minimum: PanelLayout.minimumPanel,
                                available: totalWidth, rest: PanelLayout.minimumConversation + PanelSplit.handle, edge: .leading)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { totalWidth = $0 }
        .preference(key: TranscriptOutputCount.self, value: outputs.count)
        // The outputs button in the header asks for the outputs, also while a file is open.
        .onChange(of: outputsOpen.wrappedValue) { _, isOpen in
            if isOpen { withAnimation(.easeInOut(duration: 0.2)) { preview = nil } }
        }
        .task(id: path + (working ? "#working" : "")) {
            while !Task.isCancelled {
                let path = self.path
                if let load = self.load {
                    // Without an answer the conversation already shown stays.
                    if let fresh = await Task.detached(priority: .utility, operation: { load() }).value, fresh != messages { messages = fresh }
                } else if !path.isEmpty {
                    let fresh = await Task.detached(priority: .utility) { AgentTranscript.recent(path: path) }.value
                    if fresh != messages { messages = fresh }
                }
                loaded = true
                // An earlier session does not change any more: read once.
                guard working else { break }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ row: TranscriptRow, answerable: String?) -> some View {
        if case .fold(let id, let seconds, let inner) = row {
            let key = "fold:" + id
            VStack(alignment: .leading, spacing: 6) {
                TranscriptFoldLine(text: seconds.map { tr("ws.fold.worked", AgentPathFormat.duration($0)) } ?? tr("agents.timeline.worked"),
                                   open: open.contains(key),
                                   checks: Verification.latest(TranscriptPresentation.steps(inner).compactMap(Verification.check))) { toggle(key) }
                if open.contains(key) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(inner) { flatRow($0, answerable: nil).id($0.id) }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.bottom, 2)
        } else {
            flatRow(row, answerable: answerable)
        }
    }

    /// Every row but a fold (a fold holds only these).
    @ViewBuilder
    private func flatRow(_ row: TranscriptRow, answerable: String?) -> some View {
        switch row {
        case .user(let message):
            TranscriptUserBubble(message: message)
                .padding(.top, 8)
                .padding(.bottom, 2)
        case .assistant(let message, let isFinal):
            TranscriptAnswer(message: message, isFinal: isFinal,
                             onChoose: message.id == answerable ? onReply : nil)
                .padding(.bottom, isFinal ? 8 : 2)
        case .thinking(let message):
            thinking(message)
        case .step(let step):
            stepLine(step)
        case .group(let id, let steps):
            group(id: id, steps: steps)
        case .fold:
            EmptyView()
        case .working(let since):
            TranscriptWorkingLine(since: since)
        case .live(let step):
            // The agent's task list, live, and what it does now in words rather than a bare "Thinking…".
            let tasks = TranscriptPresentation.tasks(shown)
            let activity = step.map { AgentActivity.of($0) } ?? TranscriptPresentation.activity(shown)
            VStack(alignment: .leading, spacing: 8) {
                if let tasks { TaskChecklistCard(steps: tasks) }
                TranscriptWorkLine(symbol: AgentActivityText.symbol(activity),
                                   label: AgentActivityText.headline(activity, step: tasks.flatMap(TaskChecklist.activeStep)),
                                   live: true)
                    .help(step.map(Self.label) ?? "")
            }
        }
    }

    private func group(id: String, steps: [AgentToolStep]) -> some View {
        let key = "group:" + id
        let tally = ToolTally(steps: steps)
        return VStack(alignment: .leading, spacing: 2) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(tally), label: ToolTallyText.sentence(tally),
                               failed: tally.failed, checks: tally.checks, lines: tally.lines, open: open.contains(key)) { toggle(key) }
            if open.contains(key) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { step in
                        stepLine(step)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(NookTheme.line2).frame(width: 1).padding(.leading, 9) }
            }
        }
    }

    /// One step. A step that set the agent's task list (TodoWrite, update_plan) opens to that list; a step that read or
    /// wrote a file on this Mac opens that file in the side panel.
    private func stepLine(_ step: AgentToolStep) -> some View {
        let key = "plan:" + step.id
        let tasks = step.tasks.flatMap { $0.isEmpty ? nil : $0 }
        let file = tasks == nil ? directory.flatMap { folder in step.file.map { SessionOutputs.resolve($0, in: folder) } } : nil
        return VStack(alignment: .leading, spacing: 4) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: Self.label(step),
                               failed: step.state == .failed, checks: Verification.check(step).map { [$0] } ?? [],
                               lines: step.state == .failed ? nil : step.lines,
                               open: tasks == nil ? nil : open.contains(key), reveals: file.map { $0 == preview }) {
                if let file { show(file) } else { toggle(key) }
            }
            .help(file.map { tr("ws.file.show") + " · " + AgentPathFormat.tilde($0) } ?? step.summary)
            if let tasks, open.contains(key) {
                TaskListRows(steps: tasks)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
                    .padding(.leading, 26)
                    .padding(.bottom, 4)
            }
        }
    }

    /// The agent's reasoning on one line, the whole of it a click away.
    private func thinking(_ message: AgentChatMessage) -> some View {
        let key = "think:" + message.id
        let headline = TranscriptPresentation.headline(message.text)
        let more = headline != message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 4) {
            TranscriptWorkLine(symbol: "brain", label: headline.isEmpty ? tr("agents.thought") : headline,
                               open: more ? open.contains(key) : nil) { if more { toggle(key) } }
            if more, open.contains(key) {
                Text(message.text)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.bottom, 4)
            }
        }
    }

    /// "Bash  Run the tests": the tool, then what it was about.
    private static func label(_ step: AgentToolStep) -> String {
        step.summary.isEmpty ? step.name : step.name + "  " + step.summary
    }

    private func toggle(_ key: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if open.contains(key) { open.remove(key) } else { open.insert(key) }
        }
    }

    /// Opens a file in the side panel; the file that is open already closes again.
    private func show(_ file: String) {
        withAnimation(.easeInOut(duration: 0.2)) { preview = preview == file ? nil : file }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard !shown.isEmpty || footer != nil else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

/// How many outputs the conversation found, for the button in the header above it.
struct TranscriptOutputCount: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}

// MARK: Messages

/// What you wrote: a soft bubble on the right, at most four fifths wide. A long message folds to its first lines;
/// on hover its time and a copy button appear under it.
struct TranscriptUserBubble: View {
    let message: AgentChatMessage
    @State private var expanded = false
    @State private var hovering = false

    /// The words, without the paths of the pictures sent along; those show as pictures above the bubble.
    private var parts: (text: String, images: [URL]) { ImageAttachment.splittingPaths(from: message.text) }

    private var long: Bool {
        let text = parts.text
        return text.count > 600 || text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    var body: some View {
        let parts = parts
        VStack(alignment: .trailing, spacing: 4) {
            if !parts.images.isEmpty {
                MessagePictures(urls: parts.images)
            }
            if !parts.text.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        text(parts.text)
                        if long {
                            Button(expanded ? tr("agents.message.showLess") : tr("agents.message.showFull")) {
                                withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                            }
                            .buttonStyle(.plain)
                            .font(NookTheme.font(11.5, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(NookTheme.smoke))
                }
            }
            HStack(spacing: 8) {
                if let date = message.date { TranscriptTime(date: date) }
                TranscriptCopyButton(text: message.text)
            }
            .opacity(hovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private func text(_ string: String) -> some View {
        let label = Text(string)
            .font(NookTheme.font(13.5))
            .foregroundStyle(NookTheme.paper)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        if long && !expanded {
            label
                .frame(maxHeight: 176, alignment: .top)
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 28)
                    }
                }
        } else {
            label
        }
    }
}

/// The agent's answer: formatted text on the left without a bubble. The final answer of a turn shows its copy button
/// and time on hover.
struct TranscriptAnswer: View {
    let message: AgentChatMessage
    let isFinal: Bool
    var onChoose: ((String) -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownView(text: message.text, size: 13.5, onChoose: onChoose)
            if isFinal {
                HStack(spacing: 8) {
                    TranscriptCopyButton(text: message.text)
                    if let date = message.updated ?? message.date { TranscriptTime(date: date) }
                }
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// "14:03" today, "12 Oct 14:03" before; the full date on hover.
struct TranscriptTime: View {
    let date: Date

    var body: some View {
        let text = Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
        Text(text)
            .font(NookTheme.font(11.5))
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .help(date.formatted(date: .complete, time: .shortened))
    }
}

/// Copies a message; the icon turns into a check for a moment.
struct TranscriptCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            Pasteboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(copied ? NookTheme.mint : NookTheme.textTertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr("button.copy"))
        .accessibilityLabel(tr("button.copy"))
    }
}

// MARK: Work

/// One line of the agent's work: an icon, what it did in muted text, and a chevron when it opens. The line that runs now
/// shimmers.
struct TranscriptWorkLine: View {
    let symbol: String
    let label: String
    var failed = false
    var live = false
    /// The tests, builds and linters it stands for, and how they went.
    var checks: [VerificationCheck] = []
    /// The lines its edits added and removed.
    var lines: EditLines? = nil
    /// Nil: the line does not open.
    var open: Bool? = nil
    /// Nil: the line has no file to show; true while its file is open in the side panel.
    var reveals: Bool? = nil
    var action: (() -> Void)? = nil
    @State private var hovering = false

    private var clickable: Bool { open != nil || reveals != nil }

    var body: some View {
        let content = HStack(spacing: 6) {
            Image(systemName: failed ? "exclamationmark.circle" : symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(failed ? NookTheme.coral.opacity(0.85) : NookTheme.textTertiary)
                .frame(width: 20)
            if live {
                ShimmerText(text: label)
                    .lineLimit(1)
            } else {
                Text(label)
                    .foregroundStyle(reveals == true ? NookTheme.paper
                                     : hovering && clickable ? NookTheme.paper.opacity(0.85) : NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let open {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            if let reveals {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(reveals || hovering ? 1 : 0)
            }
            if let lines { EditLinesLabel(lines: lines, size: 11) }
            if !checks.isEmpty { VerificationChips(checks: checks) }
            Spacer(minLength: 0)
        }
        .font(NookTheme.font(12.5))
        .frame(minHeight: 22)
        .contentShape(Rectangle())

        if let action, clickable {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(open == true || reveals == true ? .isSelected : [])
        } else {
            content
        }
    }
}

/// A finished turn's work, folded: "Worked for 1m 3s ›" over a hairline.
struct TranscriptFoldLine: View {
    let text: String
    let open: Bool
    /// What the turn's tests and builds came to, in sight while its work is folded.
    var checks: [VerificationCheck] = []
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                if !checks.isEmpty { VerificationChips(checks: checks) }
                Spacer(minLength: 0)
            }
            .font(NookTheme.font(12.5))
            .foregroundStyle(hovering ? NookTheme.paper.opacity(0.85) : NookTheme.textTertiary)
            .padding(.top, 2)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(NookTheme.line2.opacity(0.8)).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// Right under your message while the agent works: "Working for 12s", ticking, over a hairline.
struct TranscriptWorkingLine: View {
    let since: Date?

    var body: some View {
        Group {
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(tr("agents.timeline.workingFor", AgentPathFormat.duration(max(0, context.date.timeIntervalSince(since)))))
                        .monospacedDigit()
                }
            } else {
                Text(tr("ws.timeline.working"))
            }
        }
        .font(NookTheme.font(12.5))
        .foregroundStyle(NookTheme.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(NookTheme.line2.opacity(0.8)).frame(height: 1) }
    }
}

/// The icon of a step, after the kind of work it does (as Code's work log picks them).
enum TranscriptSymbols {
    static func symbol(_ tool: String) -> String {
        switch tool {
        case "Task", "Agent": return "person.2"
        case "TodoWrite", "Plan", "update_plan", "ExitPlanMode": return "checklist"
        case "WebSearch", "WebFetch", "web_search", "web_fetch", "google_web_search": return "globe"
        case "Skill": return "sparkles"
        default:
            switch ToolCategory.of(tool: tool) {
            case .command: return "terminal"
            case .edit: return "square.and.pencil"
            case .read: return "eye"
            case .search: return "magnifyingglass"
            case .other: return "wrench"
            }
        }
    }

    /// One kind of work keeps its own icon; mixed work gets a hammer.
    static func symbol(_ tally: ToolTally) -> String {
        let parts = tally.parts
        guard parts.count == 1, let category = parts.first?.category else { return "hammer" }
        switch category {
        case .command: return "terminal"
        case .edit: return "square.and.pencil"
        case .read: return "eye"
        case .search: return "magnifyingglass"
        case .other: return "wrench"
        }
    }
}
