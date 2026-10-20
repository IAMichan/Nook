import SwiftUI
import AppKit

/// All your Nooks, listed the way the Agents tab lists sessions: a header with the new-Nook button, a search, pinned
/// conversations first, then the rest, and the archive folded away at the bottom. Each row is a card with the title,
/// the status as the same badge the agents use (working, needs you, new answer) or how long ago, and the last answer
/// underneath. Pin and archive appear on hover, in the badge's place, so nothing shifts; right-click for the rest.
struct NookList: View {
    @ObservedObject var chat: NookChat
    @EnvironmentObject private var app: AppModel
    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: UUID?
    @State private var nameDraft = ""
    @State private var selection = ListSelection<UUID>()

    var body: some View {
        let items = chat.list(query: query, showArchived: false)
        let archived = chat.list(query: query, showArchived: true)
        let pinned = items.filter(\.pinned)
        let rest = items.filter { !$0.pinned }
        // The rows as shown, top to bottom: what select all and a ⇧-click range go by.
        let shown = (pinned + rest + (showArchived ? archived : [])).map(\.id)
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 6) {
                searchField
                SelectionModeButton(active: selection.isActive) {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if selection.isActive { selection.clear() } else { selection.begin() }
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ScrollView(showsIndicators: false) {
                    // Lazy: only the rows in view are built, and this list redraws while an answer streams in.
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if items.isEmpty && (archived.isEmpty || !showArchived) {
                            Text(query.isEmpty ? tr("nooks.none") : tr("nooks.noMatches"))
                                .font(NookTheme.font(12.5))
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(12)
                        }
                        if !pinned.isEmpty {
                            sectionLabel(tr("nooks.section.pinned"))
                            rows(pinned, now: context.date, shown: shown)
                            if !rest.isEmpty {
                                sectionLabel(tr("nooks.section.recent")).padding(.top, 8)
                            }
                        }
                        rows(rest, now: context.date, shown: shown)
                        if !archived.isEmpty {
                            archiveShelf(archived, now: context.date, shown: shown)
                        }
                    }
                }
            }
            if selection.isActive {
                selectionBar(shown: shown)
            }
        }
        .onChange(of: shown) { _, current in selection.keep(only: current) }
    }

    // MARK: Selecting several

    /// A click on a row: opens it, or with ⌘, ⇧ or while selecting, picks it.
    private func click(_ conversation: Conversation, shown: [UUID]) {
        let keys = SelectionClick.modifiers()
        withAnimation(.easeOut(duration: 0.15)) {
            switch selection.click(command: keys.command, shift: keys.shift) {
            case .open: app.openConversation(conversation.id)
            case .toggle: selection.toggle(conversation.id)
            case .extend: selection.extend(to: conversation.id, in: shown)
            }
        }
    }

    private func selectionBar(shown: [UUID]) -> some View {
        let picked = chat.conversations.filter { selection.contains($0.id) }
        let ids = Set(picked.map(\.id))
        let allPinned = !picked.isEmpty && picked.allSatisfy(\.pinned)
        let allArchived = !picked.isEmpty && picked.allSatisfy(\.archived)
        let anyUnread = picked.contains(where: \.unread)
        let idle = picked.filter { !$0.busy }
        var actions: [SelectionAction] = [
            anyUnread
                ? SelectionAction(symbol: "envelope.open", label: tr("select.markRead")) { chat.setUnread(false, ids) }
                : SelectionAction(symbol: "envelope.badge", label: tr("select.markUnread")) { chat.setUnread(true, ids) },
        ]
        if !allArchived {
            actions.append(allPinned
                ? SelectionAction(symbol: "pin.slash", label: tr("select.unpin")) { chat.setPinned(false, ids) }
                : SelectionAction(symbol: "pin", label: tr("select.pin")) { chat.setPinned(true, ids) })
        }
        actions.append(allArchived
            ? SelectionAction(symbol: "tray.and.arrow.up", label: tr("select.unarchive"), enabled: !idle.isEmpty) { chat.setArchived(false, ids) }
            : SelectionAction(symbol: "archivebox", label: tr("select.archive"), enabled: !idle.isEmpty) { chat.setArchived(true, ids) })
        actions.append(SelectionAction(symbol: "trash", label: tr("select.delete"), destructive: true, enabled: !idle.isEmpty,
                                       confirm: tr("select.deleteConfirm", idle.count)) { chat.delete(ids) })
        return SelectionBar(count: selection.count, allSelected: !shown.isEmpty && Set(shown).isSubset(of: ids),
                            actions: actions,
                            toggleAll: { selection.toggleAll(shown) },
                            done: { withAnimation(.easeOut(duration: 0.15)) { selection.clear() } })
    }

    // MARK: Header and search

    /// "Nook" with the button that starts a new one, as "Agents" has.
    private var header: some View {
        HStack(spacing: 8) {
            Text(tr("tab.nook"))
                .font(NookTheme.font(14, .semibold))
                .foregroundStyle(NookTheme.paper)
            Spacer(minLength: 4)
            Button { app.newChat() } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(chat.isEmpty ? NookTheme.paper : NookTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8).fill(chat.isEmpty ? NookTheme.smoke : Color.clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: .command)
            .help(tr("nooks.newHelp"))
            .accessibilityLabel(tr("nooks.new"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
            TextField(tr("nooks.search"), text: $query)
                .textFieldStyle(.plain)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.paper)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("button.clear"))
            }
        }
        .foregroundStyle(NookTheme.textTertiary)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NookTheme.field))
        .padding(.horizontal, 2)
    }

    // MARK: Sections

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(NookTheme.font(11.5, .medium))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }

    /// The archive as a shelf, like the settled sessions: a line with its count, opened with a click.
    private func archiveShelf(_ archived: [Conversation], now: Date, shown: [UUID]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showArchived.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(tr("nooks.section.archived", archived.count))
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize()
                    Rectangle().fill(NookTheme.line2).frame(height: 1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(showArchived ? 0 : -90))
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showArchived ? tr("compose.queue.expanded") : "")
            if showArchived {
                rows(archived, now: now, shown: shown)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func rows(_ conversations: [Conversation], now: Date, shown: [UUID]) -> some View {
        ForEach(conversations) { conversation in
            if renaming == conversation.id {
                TextField("", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .cardBackground(NookTheme.rowSelected, stroke: NookTheme.iris.opacity(0.5), radius: 12, style: .continuous)
                    .onSubmit {
                        chat.rename(conversation.id, to: nameDraft)
                        renaming = nil
                    }
                    .onExitCommand { renaming = nil }
            } else {
                NookRow(conversation: conversation, selected: conversation.id == chat.activeID, now: now,
                        onPin: { chat.togglePin(conversation.id) },
                        onArchive: { chat.setArchived(!conversation.archived, conversation.id) }) {
                    click(conversation, shown: shown)
                }
                .selectable(active: selection.isActive, selected: selection.contains(conversation.id)) {
                    withAnimation(.easeOut(duration: 0.15)) { selection.toggle(conversation.id) }
                }
                .contextMenu { contextMenu(conversation) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ conversation: Conversation) -> some View {
        Button(tr("nooks.rename")) {
            nameDraft = conversation.title
            renaming = conversation.id
        }
        if !conversation.archived {
            Button(tr(conversation.pinned ? "nooks.unpin" : "nooks.pin")) { chat.togglePin(conversation.id) }
        }
        Button(tr("ws.export.copy")) {
            Pasteboard.copy(ChatExport.markdown(conversation))
        }
        Button(tr(conversation.archived ? "nooks.unarchive" : "nooks.archive")) {
            chat.setArchived(!conversation.archived, conversation.id)
        }
        .disabled(conversation.busy)
        Divider()
        Button(tr("nooks.delete"), role: .destructive) { chat.delete(conversation.id) }
            .disabled(conversation.busy)
    }
}

/// One Nook in the list, built like a session row in the Agents tab: a soft card, the title with the status on the
/// right, the last answer underneath. A conversation that asks nothing of you recedes, so what needs you stands out.
private struct NookRow: View {
    let conversation: Conversation
    let selected: Bool
    let now: Date
    let onPin: () -> Void
    let onArchive: () -> Void
    let action: () -> Void
    @State private var hovering = false

    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering) }
    private var receded: Bool { conversation.status == .idle && !selected }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.plain)
            hoverActions
                .padding(.top, 8)
                .padding(.trailing, 8)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .onHover { hovering = $0 }
        .hoverCard { NookHoverCard(conversation: conversation) }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(conversation.title), \(statusText)")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(conversation.title)
                    .font(NookTheme.font(13.5, receded ? .regular : .medium))
                    .foregroundStyle(receded || conversation.archived ? NookTheme.textSecondary : NookTheme.paper)
                    .lineLimit(1)
                if conversation.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 6)
                slot.opacity(hovering ? 0 : 1)
            }
            Text(conversation.preview.isEmpty ? statusText : conversation.preview)
                .font(NookTheme.font(12))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .contentShape(Rectangle())
    }

    /// The status as the agents show it, otherwise how long ago.
    @ViewBuilder
    private var slot: some View {
        switch conversation.status {
        case .working:
            AgentStatusBadge(state: .working, detail: conversation.turnStarted.map { AgentFormat.short(now.timeIntervalSince($0)) })
        case .waiting:
            AgentStatusBadge(state: .approval)
        case .unread:
            AgentStatusBadge(state: .ready)
        case .idle:
            Text(AgentFormat.short(now.timeIntervalSince(conversation.updated)))
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize()
        }
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            if !conversation.archived {
                rowButton(conversation.pinned ? "pin.slash" : "pin", tr(conversation.pinned ? "nooks.unpin" : "nooks.pin"), onPin)
            }
            if !conversation.busy {
                rowButton(conversation.archived ? "tray.and.arrow.up" : "archivebox",
                          tr(conversation.archived ? "nooks.unarchive" : "nooks.archive"), onArchive)
            }
        }
    }

    private func rowButton(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .help(label)
        .accessibilityLabel(label)
    }

    private var statusText: String {
        switch conversation.status {
        case .working: return tr("nooks.working")
        case .waiting: return tr("nooks.waiting")
        case .unread: return tr("nooks.doneAt", NookDates.ago(conversation.updated))
        case .idle: return NookDates.ago(conversation.updated)
        }
    }
}

/// What a Nook shows on hover, like a session in the Agents tab: its title, when it started and was last active,
/// how many messages it holds, and the sources it may use.
private struct NookHoverCard: View {
    let conversation: Conversation

    var body: some View {
        HoverCard(title: conversation.title) {
            HoverCardRow(symbol: "clock", text: tr("nooks.card.started", NookDates.ago(conversation.created)))
            if conversation.updated > conversation.created {
                HoverCardRow(symbol: "arrow.clockwise", text: tr("nooks.card.updated", NookDates.ago(conversation.updated)))
            }
            HoverCardRow(symbol: "bubble.left.and.bubble.right", text: messageCount)
            HoverCardRow(symbol: "line.3.horizontal.decrease",
                         text: conversation.scope.isRestricted ? conversation.scope.label() : tr("scope.automaticShort"))
        }
    }

    private var messageCount: String {
        let count = conversation.messages.count
        return count == 1 ? tr("nooks.card.message") : tr("nooks.card.messages", count)
    }
}
