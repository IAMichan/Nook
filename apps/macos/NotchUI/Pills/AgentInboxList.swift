import SwiftUI
import UniformTypeIdentifiers

/// The Agents list as an inbox: pinned sessions first, then what is active, a shelf for sessions that work and need
/// nothing, one for snoozed sessions and one for what you settled. Rows that need you stay loud, the rest recede; you pin,
/// settle and snooze from the row or by dragging it, and the last such action can be undone for five seconds (⌘Z).
/// The decisions are in `InboxLayout`, `InboxDrop`, `UndoLog` and `AutoSettlePolicy`.
struct AgentInboxList: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = InboxStore.shared
    @ObservedObject private var finishedMarks = FinishedSessions.shared
    @ObservedObject private var visits = SessionVisits.shared
    @ObservedObject private var pullRequests = PullRequestSync.shared
    /// Sessions that are running or were, and earlier sessions (settled by nature).
    let items: [AgentListItem]
    let past: [AgentListItem]
    let current: String
    let now: Date
    let select: (String) -> Void

    @State private var collapsed: Set<InboxSection.Kind> = [.snoozed, .settled]
    @State private var settledLimit = InboxLayout.settledPage
    @State private var dragging: String?
    @State private var targeted: InboxSection.Kind?
    @State private var hint: String?

    private static let wakeFormat: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        return format
    }()

    // MARK: Rows

    private func attention(_ item: AgentListItem) -> AgentAttention {
        switch item.status {
        case .waiting: return .approval
        case .input: return .input
        case .failed: return .failed
        case .limited: return .limited
        case .working: return .working
        case .idle: return item.unseen ? .ready : .idle
        case .finished: return .finished
        }
    }

    private func row(_ item: AgentListItem) -> InboxRow {
        let isPast = item.id.hasPrefix("past:")
        // A process Nook only sees (id "proc-…") runs in a terminal: it never settles by itself.
        let idle = (item.status == .idle || item.status == .finished) && !item.id.hasPrefix("proc-")
        let settled = isPast || (!item.isBusy && finishedMarks.isFinished(key: item.finishKey, idle: idle, lastActive: item.started, now: now))
        return InboxRow(
            id: item.id, title: item.title, project: item.folder, attention: attention(item),
            pinned: store.state.pinned.contains(item.id), settled: settled,
            snoozedUntil: item.snoozedUntil, snoozedAt: item.snoozedAt,
            lastActivity: item.started ?? .distantPast,
            hasOpenRequest: item.status == .waiting || item.status == .input,
            isActive: item.isBusy || item.status == .working,
            unread: item.unseen
        )
    }

    private func runID(_ item: AgentListItem?) -> UUID? {
        guard let item else { return nil }
        return runID(item)
    }

    private func runID(_ item: AgentListItem) -> UUID? {
        item.id.hasPrefix("run:") ? UUID(uuidString: String(item.id.dropFirst(4))) : nil
    }

    // MARK: Body

    var body: some View {
        let all = items + past
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let rows = all.map(row)
        let visible = InboxSearch.filter(rows: rows, query: store.query)
        let sections = InboxLayout.sections(rows: visible, state: store.state, showWorking: store.showWorking, now: now,
                                            settledLimit: settledLimit, selectedID: current)
        VStack(alignment: .leading, spacing: 6) {
            searchField
            if let hint {
                Text(hint)
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.amber)
                    .padding(.horizontal, 12)
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections, id: \.kind) { section in
                        sectionView(section, sections: sections, byID: byID)
                    }
                    if sections.isEmpty { emptyState }
                }
            }
            undoNotice
        }
        .onAppear {
            pullRequests.refresh(workspace: app.workspace, now: now)
            store.undoSnooze = { ids in
                for id in ids { if let uuid = UUID(uuidString: String(id.dropFirst(4))) { app.workspace.unsnooze(uuid) } }
            }
            store.undoArchive = { ids in
                for id in ids { if let uuid = UUID(uuidString: String(id.dropFirst(4))) { app.workspace.setArchived(uuid, false) } }
            }
        }
        .onChange(of: now) { _, current in
            autoSettle(rows: rows, byID: byID, now: current)
            pullRequests.refresh(workspace: app.workspace, now: current)
        }
    }

    private var emptyState: some View {
        Text(store.query.isEmpty ? (app.history.loading ? tr("agents.checking") : tr("agents.noneWorkingNow")) : tr("inbox.noResults"))
            .font(NookTheme.font(12.5))
            .foregroundStyle(NookTheme.textTertiary)
            .padding(12)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
            TextField(tr("inbox.search.placeholder"), text: $store.query)
                .textFieldStyle(.plain)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.paper)
            if !store.query.isEmpty {
                Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
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

    @ViewBuilder
    private func sectionView(_ section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem]) -> some View {
        switch section.kind {
        case .pinned, .active:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(section.rows) { entry in entryRow(entry, in: section, sections: sections, byID: byID) }
            }
            .padding(.bottom, section.kind == .pinned ? 4 : 0)
            .modifier(DropTarget(kind: section.kind, section: section, list: self, sections: sections, byID: byID, row: nil))
        case .working, .snoozed, .settled:
            VStack(alignment: .leading, spacing: 2) {
                shelfHeader(section, sections: sections, byID: byID)
                if !collapsed.contains(section.kind) {
                    ForEach(section.rows) { entry in entryRow(entry, in: section, sections: sections, byID: byID) }
                    if section.kind == .settled, section.hiddenCount > 0 {
                        Button { settledLimit += InboxLayout.settledPage } label: {
                            Text(tr("inbox.moreSettled", min(section.hiddenCount, InboxLayout.settledPage)))
                                .font(NookTheme.font(12, .medium))
                                .foregroundStyle(NookTheme.textTertiary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 6)
            .modifier(DropTarget(kind: section.kind, section: section, list: self, sections: sections, byID: byID, row: nil))
        }
    }

    private func shelfHeader(_ section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem]) -> some View {
        let open = !collapsed.contains(section.kind)
        let count = section.rows.count + section.hiddenCount
        let ghost = ghostLabel(for: section.kind, sections: sections)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if open { collapsed.insert(section.kind) } else { collapsed.remove(section.kind) }
            }
        } label: {
            HStack(spacing: 8) {
                Text(tr("inbox.section." + section.kind.rawValue, count))
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(section.kind == .snoozed ? NookTheme.textSecondary : NookTheme.textTertiary)
                Rectangle().fill(NookTheme.line2).frame(height: 1)
                if let ghost {
                    Text(ghost)
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(NookTheme.iris)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(NookTheme.iris.opacity(0.14)))
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? tr("compose.queue.expanded") : "")
    }

    /// What dropping the dragged row on this section would do, named before you let go.
    private func ghostLabel(for kind: InboxSection.Kind, sections: [InboxSection]) -> String? {
        guard targeted == kind, let dragging, let (section, entry) = locate(dragging, in: sections) else { return nil }
        let result = InboxDrop.decide(row: entry.row, from: section.kind, to: kind)
        return result.labelKey.map { tr($0) }
    }

    private func locate(_ id: String, in sections: [InboxSection]) -> (InboxSection, InboxEntry)? {
        for section in sections {
            if let entry = section.rows.first(where: { $0.id == id }) { return (section, entry) }
        }
        return nil
    }

    // MARK: A row

    @ViewBuilder
    private func entryRow(_ entry: InboxEntry, in section: InboxSection, sections: [InboxSection], byID: [String: AgentListItem]) -> some View {
        if let item = byID[entry.id] {
            let slim = section.kind == .snoozed || section.kind == .settled
            let isRun = runID(item) != nil
            let snoozeActive = section.kind == .snoozed
            AgentListRow(
                item: item, now: now, selected: current == item.id,
                receded: entry.receded, pinned: entry.row.pinned, woke: entry.woke, slim: slim,
                wakeLabel: snoozeActive ? item.snoozedUntil.map { tr("inbox.snooze.until", Self.wakeFormat.string(from: $0)) } : nil,
                actions: AgentRowActions(
                    pinned: entry.row.pinned,
                    onPin: { entry.row.pinned ? store.unpin(item.id) : pinAndUnsettle(item, entry) },
                    settled: entry.row.settled,
                    onSettle: { entry.row.settled ? store.unsettle([item]) : store.settle([item]) },
                    onSnooze: isRun ? { snooze(item, $0) } : nil,
                    onWake: isRun && snoozeActive ? { wake(item) } : nil),
                pullRequest: runID(item).flatMap { pullRequests.badge($0) }
            ) {
                select(item.id)
                if entry.woke { store.dismissWoke(item.id) }
            }
            .contextMenu { contextMenu(item, entry) }
            .onDrag {
                dragging = item.id
                return NSItemProvider(object: item.id as NSString)
            }
            .modifier(DropTarget(kind: section.kind, section: section, list: self, sections: sections, byID: byID, row: entry.id))
        }
    }

    private func pinAndUnsettle(_ item: AgentListItem, _ entry: InboxEntry) {
        if entry.row.settled { store.unsettle([item], record: false) }
        store.pin(item.id)
    }

    // MARK: Actions

    private func snooze(_ item: AgentListItem, _ choice: SnoozePolicy.Choice) {
        guard let id = runID(item) else { return }
        app.workspace.snooze(id, choice)
        store.note(.snoozed, ids: [item.id])
    }

    private func wake(_ item: AgentListItem) {
        guard let id = runID(item) else { return }
        app.workspace.unsnooze(id)
    }

    @ViewBuilder
    private func contextMenu(_ item: AgentListItem, _ entry: InboxEntry) -> some View {
        Button(entry.row.pinned ? tr("inbox.unpin") : tr("inbox.pin")) {
            entry.row.pinned ? store.unpin(item.id) : pinAndUnsettle(item, entry)
        }
        if item.isBusy {
            Button(tr("inbox.settle")) {}.disabled(true)
        } else if item.id.hasPrefix("past:") && entry.row.settled {
            // Earlier sessions are settled by nature; only a session that ran can be reopened.
            EmptyView()
        } else {
            Button(entry.row.settled ? tr("inbox.reopen") : tr("inbox.settle")) {
                entry.row.settled ? store.unsettle([item]) : store.settle([item])
            }
        }
        if let id = runID(item), let run = app.workspace.run(id) {
            if let until = run.snoozedUntil, until > now {
                Button(tr("agents.snooze.cancel")) { wake(item) }
            } else if !item.isBusy {
                Menu(tr("agents.snooze.menu")) {
                    ForEach(SnoozePolicy.Choice.allCases, id: \.self) { choice in
                        Button(tr("agents.snooze." + choice.rawValue)) { snooze(item, choice) }
                    }
                }
            }
            Divider()
            Button(tr("agents.fork")) {
                if let forked = app.workspace.fork(id) { select("run:" + forked.uuidString) }
            }
            .disabled(!app.workspace.canTransfer(id))
        }
        Button(tr("inbox.markUnread")) { visits.markUnread(item.id) }
        Divider()
        Menu(tr("inbox.copy")) {
            Button(tr("inbox.copy.path")) { copy(item.path) }
            if let branch = item.branch { Button(tr("inbox.copy.branch")) { copy(branch) } }
            Button(tr("inbox.copy.id")) { copy(item.id) }
        }
        if let id = runID(item) {
            Button(tr("agents.run.archive")) {
                app.workspace.setArchived(id, true)
                store.note(.archived, ids: [item.id])
            }
            .disabled(item.isBusy)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Drops

    /// Applies a drop: onto a row of the same section it reorders, onto a section it changes the session's state.
    fileprivate func drop(on kind: InboxSection.Kind, row targetRow: String?, section: InboxSection, sections: [InboxSection],
                          byID: [String: AgentListItem]) -> Bool {
        defer { dragging = nil; targeted = nil }
        guard let dragged = dragging, let (from, entry) = locate(dragged, in: sections), let item = byID[dragged] else { return false }
        if from.kind == kind, let targetRow {
            let ids = section.rows.map(\.id)
            guard let gap = ids.firstIndex(of: targetRow),
                  let target = InboxDrop.reorderTarget(ids: ids, dragged: dragged, gap: gap) else { return true }
            store.reorder(dragged, toIndex: target, within: section)
            return true
        }
        switch InboxDrop.decide(row: entry.row, from: from.kind, to: kind) {
        case .pin: pinAndUnsettle(item, entry)
        case .unpin: store.unpin(item.id)
        case .settle: store.settle([item])
        case .unsettle: store.unsettle([item])
        case .wake: wake(item)
        case .reorder: break
        case .rejected(let reason):
            show(tr("inbox.drop." + reason.rawValue))
        }
        return true
    }

    fileprivate func setTargeted(_ kind: InboxSection.Kind, _ on: Bool) {
        if on { targeted = kind } else if targeted == kind { targeted = nil }
    }

    private func show(_ text: String) {
        hint = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if hint == text { hint = nil }
        }
    }

    // MARK: Auto-settle

    private func autoSettle(rows: [InboxRow], byID: [String: AgentListItem], now: Date) {
        let ids = store.autoSettleCandidates(rows: rows, prMerged: { id in runID(byID[id]).map { pullRequests.merged($0) } ?? false }, now: now)
        let settle = ids.compactMap { byID[$0] }
        if !settle.isEmpty { store.settle(settle, now: now, record: false) }
    }

    // MARK: Undo

    private var undoNotice: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let entry = store.undoLog.current(now: context.date) {
                HStack(spacing: 8) {
                    Text(tr(entry.messageKey, entry.count))
                        .font(NookTheme.font(12))
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(tr("inbox.undo")) { store.undo() }
                        .buttonStyle(.plain)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.iris)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NookTheme.smoke))
                .transition(.opacity)
            }
        }
    }
}

/// A section or a row as a place to drop a dragged session.
private struct DropTarget: ViewModifier {
    let kind: InboxSection.Kind
    let section: InboxSection
    let list: AgentInboxList
    let sections: [InboxSection]
    let byID: [String: AgentListItem]
    let row: String?

    func body(content: Content) -> some View {
        content.onDrop(of: [.plainText], isTargeted: Binding(get: { false }, set: { list.setTargeted(kind, $0) })) { _ in
            list.drop(on: kind, row: row, section: section, sections: sections, byID: byID)
        }
    }
}
