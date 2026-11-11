import SwiftUI

/// "Lineage · 2 running" in a session's header: the sessions related to this one in a
/// dropdown. First the parent and the forks and comparisons made from it, then the tasks it delegated that still work
/// (each with a stop button), the ones that ended under "Previous agents" (folded), and its side chats. Delegated tasks
/// and side chats have no row in the Agents list (`SubThreadListing`), so this is where you open them.
struct LineageControl: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var workspace: WorkspaceManager
    let runID: UUID
    @State private var previousOpen = false

    var body: some View {
        let groups = workspace.lineageGroups(of: runID)
        if !groups.isEmpty {
            ComposerDropdown(width: 300, scrolls: true) {
                trigger(groups)
            } content: {
                rows(groups)
            }
            .help(tr("lineage.control.help"))
            .accessibilityLabel(label(groups))
        }
    }

    private func label(_ groups: LineageGroups) -> String {
        let running = groups.running + groups.runningSideChats
        return running > 0 ? tr("lineage.control.running", running) : tr("lineage.control")
    }

    private func trigger(_ groups: LineageGroups) -> some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            Image(icon: "arrow.triangle.branch")
            Text(label(groups)).lineLimit(1)
            // Something in there waits for you: the same amber as everywhere else.
            if groups.needsYou {
                Circle().fill(NookTheme.amber).frame(width: 6, height: 6)
            }
            Image(icon: "chevron.down").font(NookTheme.font(8, .bold))
        }
        .font(NookTheme.TextStyle.label)
        .foregroundStyle(NookTheme.textTertiary)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func rows(_ groups: LineageGroups) -> some View {
        ForEach(groups.related, id: \.node.id) { row($0) }
        ForEach(groups.active, id: \.node.id) { row($0, stoppable: true) }
        if !groups.previous.isEmpty {
            if !groups.related.isEmpty || !groups.active.isEmpty { DropdownDivider() }
            DropdownRow(symbol: "clock.arrow.circlepath", title: tr("lineage.previous"),
                        trailing: String(groups.previous.count), staysOpen: true, expanded: previousOpen) {
                withAnimation(NookTheme.reveal) { previousOpen.toggle() }
            }
            if previousOpen { ForEach(groups.previous, id: \.node.id) { row($0) } }
        }
        if !groups.sideChats.isEmpty {
            DropdownHeader(title: groups.runningSideChats > 0
                           ? tr("lineage.sideChats.running", groups.runningSideChats) : tr("lineage.sideChats"))
            ForEach(groups.sideChats, id: \.node.id) { row($0) }
        }
    }

    private func row(_ row: LineageGroups.Row, stoppable: Bool = false) -> some View {
        let node = row.node
        return HStack(spacing: 0) {
            DropdownRow(symbol: Self.symbol(row.role), title: node.title, detail: tr(Self.roleKey(row.role)),
                        trailing: tr(Self.statusKey(node.status)), tint: Self.tint(node.status)) {
                open(node.id)
            }
            if stoppable && node.status.isLive {
                Button { workspace.cancelDelegated(node.id) } label: {
                    Image(icon: "stop.circle")
                        .font(NookTheme.font(9, .bold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("lineage.stop", node.title))
                .accessibilityLabel(tr("lineage.stop", node.title))
            }
        }
    }

    /// Opens the session in place of this one; an archived one comes back first, so it can be found again.
    private func open(_ id: UUID) {
        if workspace.run(id)?.archived == true { workspace.setArchived(id, false) }
        app.viewModel.selectedAgentID = "run:" + id.uuidString
    }

    static func symbol(_ role: LineageGroups.Row.Role) -> String {
        switch role {
        case .parent: return "arrow.turn.left.up"
        case .child(.fork): return "arrow.triangle.branch"
        case .child(.comparison): return "square.stack.3d.up"
        case .child(.delegated): return "arrow.turn.down.right"
        case .child(.side): return "bubble.left.and.bubble.right"
        }
    }

    /// relationship labels: "Parent agent" for the session that delegated this one, "Parent thread" otherwise.
    static func roleKey(_ role: LineageGroups.Row.Role) -> String {
        switch role {
        case .parent(.delegated): return "lineage.role.parentAgent"
        case .parent: return "lineage.role.parentThread"
        case .child(.fork): return "lineage.role.fork"
        case .child(.comparison): return "lineage.role.comparison"
        case .child(.delegated): return "lineage.role.subThread"
        case .child(.side): return "lineage.role.sideChat"
        }
    }

    static func statusKey(_ status: LineageStatus) -> String {
        switch status {
        case .working: return "lineage.status.working"
        case .approval: return "lineage.status.approval"
        case .question: return "lineage.status.question"
        case .done: return "lineage.status.done"
        case .failed: return "lineage.status.failed"
        case .stopped: return "lineage.status.stopped"
        }
    }

    /// Waiting on you is amber, an error coral; the rest keeps the row's own colors.
    static func tint(_ status: LineageStatus) -> Color? {
        switch status {
        case .approval, .question: return NookTheme.amber
        case .failed: return NookTheme.coralSoft
        case .working, .done, .stopped: return nil
        }
    }
}
