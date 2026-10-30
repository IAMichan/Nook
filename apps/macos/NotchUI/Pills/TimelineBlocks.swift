import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One block of a session's timeline (see TimelinePresentation): a single event, a group of tool calls behind one
/// sentence, or a finished turn folded into "Worked for 2m 13s". Groups and folds open in place, drawn with the same
/// views as an agent's own transcript (`TranscriptWorkGroup`, `TranscriptFold`).
struct TimelineBlockView: View, Equatable {
    let block: TimelineBlock
    let expanded: Set<String>
    /// Everything else its rows show (the session's status, what is open, the find bar's match…). With it, a block that
    /// did not change is not drawn again while the agent writes into the last one (see `.equatable()` where it is used);
    /// without it, it always is.
    var context: TimelineRowContext? = nil
    let toggle: (String) -> Void
    let eventRow: (RunEvent) -> AnyView

    /// The closures are made again on every redraw of the session and read the panel's current state when they run, so
    /// they do not count.
    static func == (lhs: TimelineBlockView, rhs: TimelineBlockView) -> Bool {
        guard let context = lhs.context else { return false }
        return context == rhs.context && lhs.expanded == rhs.expanded && lhs.block == rhs.block
    }

    var body: some View {
        switch block {
        case .event(let event):
            eventRow(event)
        case .tools(let id, let events, let tally):
            let key = "group:" + id.uuidString
            TranscriptWorkGroup(tally: tally, open: expanded.contains(key), toggle: { toggle(key) }) {
                ForEach(events) { eventRow($0) }
            }
        case .fold(let id, let seconds, let blocks, let checks):
            // What the turn's tests and builds came to stays in sight while its work is folded away.
            let key = "fold:" + id.uuidString
            TranscriptFold(text: tr("ws.fold.worked", AgentPathFormat.duration(seconds)), open: expanded.contains(key),
                           checks: checks, toggle: { toggle(key) }) {
                ForEach(blocks) { inner in
                    TimelineBlockView(block: inner, expanded: expanded, context: context, toggle: toggle, eventRow: eventRow)
                }
            }
        }
    }
}

/// What a session's timeline rows show besides their block: each change draws every block again.
struct TimelineRowContext: Equatable {
    /// Bumped when the session's events changed in any way but more text in the answer being written: the plan card,
    /// the turn cards and the menus of your messages read the whole session.
    var structure: Int
    var status: RunStatus
    var directory: String?
    /// The event the find bar is on.
    var highlighted: UUID?
    /// The events whose details are open.
    var openEvents: Set<UUID>
    /// The file open beside the conversation.
    var shownFile: String?
    /// The lines git counted per turn and file.
    var counted: [String: [String: EditLines]]
}

/// "+7 −8": the lines an edit (or a group of edits) added and removed.
struct EditLinesLabel: View {
    let lines: EditLines
    var size: CGFloat = 10.5

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Text("+\(lines.added)").foregroundStyle(NookTheme.mint.opacity(0.85))
            Text("−\(lines.removed)").foregroundStyle(NookTheme.coral.opacity(0.85))
        }
        .font(NookTheme.mono(size))
        .monospacedDigit()
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Messages waiting for the turn to end, in the tray above the composer: each can be taken back before it goes out.
struct QueuedMessagesStrip: View {
    let queue: MessageQueue
    /// The message that is being edited in the composer.
    var editing: UUID? = nil
    let remove: (UUID) -> Void
    var edit: ((UUID) -> Void)? = nil
    var move: ((UUID, Int) -> Void)? = nil
    /// Sends the message right away: into the running turn, or as the next turn when the agent is idle. Nil when
    /// neither can happen right now.
    var sendNow: ((UUID) -> Void)? = nil
    @State private var collapsed = false
    @State private var hovered: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            Button { withAnimation(NookTheme.reveal) { collapsed.toggle() } } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(systemName: "chevron.down")
                        .font(NookTheme.font(8.5, .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(tr("compose.queue.title", queue.count))
                        .font(NookTheme.TextStyle.label)
                    Spacer(minLength: 8)
                    Text(queue.isHeld ? tr("compose.queue.held") : tr("compose.queue.note"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(queue.isHeld ? NookTheme.amber : NookTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(NookTheme.textSecondary)
                .padding(.horizontal, NookTheme.Spacing.sm)
                .padding(.vertical, NookTheme.Spacing.xxs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("compose.queue.title", queue.count))
            .accessibilityHint(queue.isHeld ? tr("compose.queue.held") : tr("compose.queue.note"))
            .accessibilityValue(collapsed ? "" : tr("compose.queue.expanded"))
            if !collapsed {
                ForEach(Array(queue.messages.enumerated()), id: \.element.id) { index, message in
                    row(message, index: index)
                }
            }
        }
    }

    /// One waiting message: its place in line, its text, and its actions. The actions show under the pointer (and while
    /// the message is open in the box), on the row's own fill so the text runs out softly underneath them.
    private func row(_ message: QueuedMessage, index: Int) -> some View {
        let isEditing = editing == message.id
        let showsActions = hovered == message.id || isEditing
        let fill = NookTheme.rowFill(selected: isEditing, hovering: hovered == message.id, rest: .clear)
        return HStack(spacing: NookTheme.Spacing.md) {
            position(index, editing: isEditing)
            Text(ToolSummary.oneLine(ContextRefs.visible(message.text), 120))
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(isEditing ? NookTheme.paper : NookTheme.textStrong)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .trailing) {
            actions(message, index: index, isEditing: isEditing)
                .rowActionsBackdrop(fill)
                .opacity(showsActions ? 1 : 0)
                .allowsHitTesting(showsActions)
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.xs)
        .contentShape(Rectangle())
        // The tray above the composer is the card; the row under the pointer and the one open in the box stand out of it.
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(fill))
        .onHover { inside in
            if inside { hovered = message.id } else if hovered == message.id { hovered = nil }
        }
        .animation(NookTheme.hover, value: showsActions)
        .accessibilityElement(children: .contain)
    }

    /// Its place in line ("1", "2"…), or a pencil while it is open in the box.
    private func position(_ index: Int, editing: Bool) -> some View {
        ZStack {
            Circle().fill(editing ? NookTheme.graphite : NookTheme.smoke)
            if editing {
                Image(systemName: "pencil").font(NookTheme.font(9, .bold))
            } else {
                Text("\(index + 1)").font(NookTheme.rounded(10, .semibold)).monospacedDigit()
            }
        }
        .foregroundStyle(editing ? NookTheme.paper : NookTheme.textSecondary)
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    /// Send now first (what you reach for most), then edit and remove; moving up and down after a line of their own.
    private func actions(_ message: QueuedMessage, index: Int, isEditing: Bool) -> some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if let sendNow { iconButton("paperplane.fill", tr("compose.queue.sendNow"), enabled: !isEditing) { sendNow(message.id) } }
            if let edit { iconButton("pencil", tr("compose.queue.edit"), enabled: !isEditing) { edit(message.id) } }
            iconButton("xmark", tr("compose.queue.remove"), enabled: true) { remove(message.id) }
            if let move, queue.count > 1 {
                NookDivider(vertical: true)
                    .frame(height: 12)
                    .padding(.horizontal, NookTheme.Spacing.xxs)
                iconButton("arrow.up", tr("compose.queue.up"), enabled: index > 0) { move(message.id, index - 1) }
                iconButton("arrow.down", tr("compose.queue.down"), enabled: index < queue.count - 1) { move(message.id, index + 1) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol, label, height: 22, width: 22, enabled: enabled, action)
    }
}

/// "Ran 3 commands and changed 2 files": the two most important kinds of work, then how many other actions.
enum ToolTallyText {
    static func sentence(_ tally: ToolTally) -> String {
        let parts = tally.parts
        guard !parts.isEmpty else { return tr("ws.group.other.many", 0) }
        let named = parts.prefix(2).map { phrase($0.category, $0.count) }
        let rest = parts.dropFirst(2).reduce(0) { $0 + $1.count }
        let text = rest > 0 ? tr("ws.group.more", named[0], named[1], rest)
            : (named.count == 2 ? tr("ws.group.and", named[0], named[1]) : named[0])
        // "changed 2 files" opens a sentence of its own with a capital.
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func phrase(_ category: ToolCategory, _ count: Int) -> String {
        let key: String
        switch category {
        case .command: key = "ws.group.command"
        case .edit: key = "ws.group.edit"
        case .read: key = "ws.group.read"
        case .search: key = "ws.group.search"
        case .other: key = "ws.group.other"
        }
        return count == 1 ? tr(key + ".one") : tr(key + ".many", count)
    }
}

/// A plan the agent proposed in Plan mode (Claude Code's ExitPlanMode, a Codex plan): the plan itself, and the button
/// that carries it out (Agent mode, then "implement the plan").
struct PlanCard: View {
    let text: String
    let canAct: Bool
    /// "Implement in a new session": the plan goes to a fork, this session stays as it is.
    var implementInNew: (() -> Void)? = nil
    let implement: () -> Void
    @State private var open = false
    @State private var copied = false

    private var title: String { PlanPreview.title(from: text) ?? tr("ws.plan.title") }
    private var collapsible: Bool { PlanPreview.needsExpand(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "list.bullet.clipboard").font(NookTheme.font(11, .semibold))
                Text(tr("ws.plan.title")).font(NookTheme.TextStyle.strong)
                Spacer(minLength: 0)
                iconButton(copied ? "checkmark" : "doc.on.doc", tr("ws.plan.copy")) {
                    Pasteboard.copy(text)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                iconButton("square.and.arrow.down", tr("ws.plan.save"), save)
            }
            .foregroundStyle(NookTheme.iris)
            MarkdownView(text: collapsible && !open ? PlanPreview.preview(text) : text, size: 13)
            if collapsible {
                Button { withAnimation(NookTheme.reveal) { open.toggle() } } label: {
                    Text(open ? tr("ws.plan.collapse") : tr("ws.plan.expand"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.iris)
                }
                .buttonStyle(.plain)
            }
            if canAct {
                HStack(spacing: NookTheme.Spacing.md) {
                    Spacer()
                    if let implementInNew {
                        NookGhostButton(title: tr("ws.plan.implementNew"), action: implementInNew)
                    }
                    NookPrimaryButton(title: tr("ws.plan.implement"), action: implement)
                }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .cardBackground(NookTheme.surface, stroke: NookTheme.iris.opacity(0.25), radius: NookTheme.Radius.panel, style: .continuous)
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        ToolbarIconButton(symbol, help, height: 20, width: 20, action)
    }

    /// "Save as file"; the name comes from the plan's title.
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PlanPreview.fileName(forTitle: title)
        panel.allowedContentTypes = [.plainText]
        if panel.runAboveNotch() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
