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
    /// Folds, groups and thoughts you opened.
    @State private var open: Set<String> = []

    private var shown: [AgentChatMessage] { messages.isEmpty ? fallback : messages }

    var body: some View {
        let rows = TranscriptPresentation.rows(shown, working: working)
        // Only the very last answer can still be answered by tapping one of its options.
        let answerable = working ? nil : shown.last(where: { $0.kind == .assistant })?.id
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
        .task(id: path + (working ? "#working" : "")) {
            while !Task.isCancelled {
                let path = self.path
                if let load = self.load {
                    // Without an answer the conversation already shown stays.
                    if let fresh = await Task.detached(priority: .utility) { load() }.value, fresh != messages { messages = fresh }
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
                                   open: open.contains(key)) { toggle(key) }
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
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: Self.label(step),
                               failed: step.state == .failed)
                .help(step.summary)
        case .group(let id, let steps):
            group(id: id, steps: steps)
        case .fold:
            EmptyView()
        case .working(let since):
            TranscriptWorkingLine(since: since)
        case .live(let step):
            if let step {
                TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: Self.label(step), live: true)
            } else {
                TranscriptWorkLine(symbol: "brain", label: tr("agents.timeline.thinking"), live: true)
            }
        }
    }

    private func group(id: String, steps: [AgentToolStep]) -> some View {
        let key = "group:" + id
        let tally = ToolTally(steps: steps)
        return VStack(alignment: .leading, spacing: 2) {
            TranscriptWorkLine(symbol: TranscriptSymbols.symbol(tally), label: ToolTallyText.sentence(tally),
                               failed: tally.failed, open: open.contains(key)) { toggle(key) }
            if open.contains(key) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { step in
                        TranscriptWorkLine(symbol: TranscriptSymbols.symbol(step.name), label: Self.label(step),
                                           failed: step.state == .failed)
                            .help(step.summary)
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(NookTheme.line2).frame(width: 1).padding(.leading, 9) }
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

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        guard !shown.isEmpty || footer != nil else { return }
        proxy.scrollTo("bottom", anchor: .bottom)
    }
}

// MARK: Messages

/// What you wrote: a soft bubble on the right, at most four fifths wide. A long message folds to its first lines;
/// on hover its time and a copy button appear under it.
struct TranscriptUserBubble: View {
    let message: AgentChatMessage
    @State private var expanded = false
    @State private var hovering = false

    private var long: Bool {
        message.text.count > 600 || message.text.split(separator: "\n", omittingEmptySubsequences: false).count > 8
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                VStack(alignment: .leading, spacing: 6) {
                    text
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
    private var text: some View {
        let label = Text(message.text)
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
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
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
    /// Nil: the line does not open.
    var open: Bool? = nil
    var action: (() -> Void)? = nil
    @State private var hovering = false

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
                    .foregroundStyle(hovering && open != nil ? NookTheme.paper.opacity(0.85) : NookTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let open {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            Spacer(minLength: 0)
        }
        .font(NookTheme.font(12.5))
        .frame(minHeight: 22)
        .contentShape(Rectangle())

        if let action, open != nil {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityAddTraits(open == true ? .isSelected : [])
        } else {
            content
        }
    }
}

/// A finished turn's work, folded: "Worked for 1m 3s ›" over a hairline.
struct TranscriptFoldLine: View {
    let text: String
    let open: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(text)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
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
