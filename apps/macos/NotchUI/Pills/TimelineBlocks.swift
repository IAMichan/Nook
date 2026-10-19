import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// One block of a session's timeline (see TimelinePresentation): a single event, a group of tool calls behind one
/// sentence, or a finished turn folded into "Worked for 2m 13s". Groups and folds open in place.
struct TimelineBlockView: View {
    let block: TimelineBlock
    let expanded: Set<String>
    let toggle: (String) -> Void
    let eventRow: (RunEvent) -> AnyView

    var body: some View {
        switch block {
        case .event(let event):
            eventRow(event)
        case .tools(let id, let events, let tally):
            let key = "group:" + id.uuidString
            VStack(alignment: .leading, spacing: 8) {
                TimelineSummaryRow(symbol: tally.failed ? "exclamationmark.triangle" : Self.symbol(tally),
                                   text: ToolTallyText.sentence(tally), open: expanded.contains(key),
                                   tint: tally.failed ? NookTheme.coralSoft : nil) { toggle(key) }
                if expanded.contains(key) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events) { eventRow($0) }
                    }
                    .padding(.leading, 18)
                }
            }
        case .fold(let id, let seconds, let blocks):
            let key = "fold:" + id.uuidString
            VStack(alignment: .leading, spacing: 10) {
                TimelineSummaryRow(symbol: "checkmark.circle", text: tr("ws.fold.worked", AgentPathFormat.duration(seconds)),
                                   open: expanded.contains(key), tint: nil) { toggle(key) }
                if expanded.contains(key) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(blocks) { inner in
                            TimelineBlockView(block: inner, expanded: expanded, toggle: toggle, eventRow: eventRow)
                        }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(NookTheme.line2).frame(width: 1) }
                }
            }
        }
    }

    /// The symbol of the group's most important kind of work.
    private static func symbol(_ tally: ToolTally) -> String {
        switch tally.parts.first?.category {
        case .command: return "terminal"
        case .edit: return "pencil"
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        default: return "wrench.and.screwdriver"
        }
    }
}

/// A quiet, clickable line that opens what it summarizes.
struct TimelineSummaryRow: View {
    let symbol: String
    let text: String
    let open: Bool
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)).frame(width: 14)
                Text(text).lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .opacity(hovering || open ? 0.9 : 0.5)
                Spacer(minLength: 0)
            }
            .font(NookTheme.font(12))
            .foregroundStyle(tint ?? (hovering ? NookTheme.textSecondary : NookTheme.textTertiary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: open)
        .accessibilityAddTraits(open ? .isSelected : [])
    }
}

/// While the agent works: one line with what it is doing, the headline of its latest thought, and for how long.
struct LiveActivityRow: View {
    let live: LiveActivity
    let since: Date?
    let waiting: Bool
    /// Waiting for an answer to a question rather than for an approval.
    var asking = false
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PulseDot(color: waiting ? NookTheme.amber : accent, animated: !waiting)
                .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(waiting ? tr(asking ? "ws.timeline.asking" : "ws.timeline.waiting") : (live.tool ?? tr("ws.timeline.working")))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let since, !waiting {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(AgentPathFormat.duration(context.date.timeIntervalSince(since)))
                                .foregroundStyle(NookTheme.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
                if let thought = live.thought, !waiting {
                    ShimmerText(text: thought)
                        .lineLimit(1)
                }
            }
            .font(NookTheme.font(12))
            Spacer(minLength: 0)
        }
    }
}

/// Messages waiting for the turn to end, above the composer: each can be taken back before it goes out.
struct QueuedMessagesStrip: View {
    let queue: MessageQueue
    /// The message that is being edited in the composer.
    var editing: UUID? = nil
    let remove: (UUID) -> Void
    var edit: ((UUID) -> Void)? = nil
    /// Take the message into the running turn now; nil when the agent cannot be steered right now.
    var steer: ((UUID) -> Void)? = nil
    var move: ((UUID, Int) -> Void)? = nil
    /// After a stop or a failure the queue waits for you: this sends the first message now.
    var sendNow: (() -> Void)? = nil
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text(tr("compose.queue.title", queue.count))
                        .font(NookTheme.font(11.5, .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(NookTheme.textSecondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("compose.queue.title", queue.count))
            .accessibilityValue(collapsed ? "" : tr("compose.queue.expanded"))
            if !collapsed {
                ForEach(Array(queue.messages.enumerated()), id: \.element.id) { index, message in
                    row(message, index: index)
                }
                HStack(spacing: 8) {
                    Text(queue.isHeld ? tr("compose.queue.held") : tr("compose.queue.note"))
                        .font(NookTheme.font(11))
                        .foregroundStyle(queue.isHeld ? NookTheme.amber : NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if let sendNow { SmallGhostButton(title: tr("compose.queue.sendNow"), action: sendNow) }
                }
                .padding(.leading, 4)
            }
        }
    }

    private func row(_ message: QueuedMessage, index: Int) -> some View {
        let isEditing = editing == message.id
        return HStack(spacing: 8) {
            Image(systemName: isEditing ? "pencil" : "clock").font(.system(size: 10, weight: .semibold))
            Text(ToolSummary.oneLine(ContextRefs.visible(message.text), 120)).lineLimit(1)
            Spacer(minLength: 6)
            if let move, queue.count > 1 {
                iconButton("chevron.up", tr("compose.queue.up"), enabled: index > 0) { move(message.id, index - 1) }
                iconButton("chevron.down", tr("compose.queue.down"), enabled: index < queue.count - 1) { move(message.id, index + 1) }
            }
            if let edit { iconButton("pencil", tr("compose.queue.edit"), enabled: !isEditing) { edit(message.id) } }
            if let steer { iconButton("arrow.turn.down.right", tr("compose.queue.steerNow"), enabled: !isEditing) { steer(message.id) } }
            iconButton("xmark", tr("compose.queue.remove"), enabled: true) { remove(message.id) }
        }
        .font(NookTheme.font(12))
        .foregroundStyle(isEditing ? NookTheme.paper : NookTheme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isEditing ? NookTheme.smoke : NookTheme.field))
    }

    private func iconButton(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.35)
        .disabled(!enabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// "Ran 3 commands and changed 2 files": the two most important kinds of work, then how many other actions.
enum ToolTallyText {
    static func sentence(_ tally: ToolTally) -> String {
        let parts = tally.parts
        guard !parts.isEmpty else { return tr("ws.group.other.many", 0) }
        let named = parts.prefix(2).map { phrase($0.category, $0.count) }
        let rest = parts.dropFirst(2).reduce(0) { $0 + $1.count }
        if rest > 0 { return tr("ws.group.more", named[0], named[1], rest) }
        return named.count == 2 ? tr("ws.group.and", named[0], named[1]) : named[0]
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
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").font(.system(size: 11, weight: .semibold))
                Text(tr("ws.plan.title")).font(NookTheme.font(12, .semibold))
                Spacer(minLength: 0)
                iconButton(copied ? "checkmark" : "doc.on.doc", tr("ws.plan.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                }
                iconButton("square.and.arrow.down", tr("ws.plan.save"), save)
            }
            .foregroundStyle(NookTheme.iris)
            MarkdownView(text: collapsible && !open ? PlanPreview.preview(text) : text, size: 12.5)
            if collapsible {
                Button { withAnimation(.easeInOut(duration: 0.15)) { open.toggle() } } label: {
                    Text(open ? tr("ws.plan.collapse") : tr("ws.plan.expand"))
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.iris)
                }
                .buttonStyle(.plain)
            }
            if canAct {
                HStack(spacing: 8) {
                    Spacer()
                    if let implementInNew {
                        NookGhostButton(title: tr("ws.plan.implementNew"), action: implementInNew)
                    }
                    NookPrimaryButton(title: tr("ws.plan.implement"), action: implement)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.iris.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NookTheme.iris.opacity(0.25), lineWidth: 1))
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// "Save as file"; the name comes from the plan's title.
    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PlanPreview.fileName(forTitle: title)
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
