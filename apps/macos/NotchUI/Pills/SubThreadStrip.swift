import SwiftUI
import AppKit

/// Above a session's composer: the tasks it delegated (`delegate_task`), the way t3code
/// shows a thread's subagents. A row opens the sub-thread live beside the main thread, in the session's side panel, so
/// you can follow it and answer its questions there; another row swaps it, the open row (or the tab's close button)
/// closes it. ⌘-click or the row's menu opens it in place of the main thread, as without room beside it (a narrow notch).
/// One that ended stays until your next message here.
struct SubThreadStrip: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.sessionSide) private var side
    @ObservedObject var workspace: WorkspaceManager
    let threads: [WorkspaceRun]
    /// The strip's width: a narrow one leaves out the agents' names before the stats (`SubThreadStats.providerWidth`).
    @State private var width: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            ForEach(threads, id: \.id) { thread in row(thread) }
        }
        // Each row has its own small inset, for the mark of the one open beside: together they line up as before.
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, 5)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
        .onLayoutWidthChange { width = $0 }
    }

    private func row(_ thread: WorkspaceRun) -> some View {
        let asks = !(workspace.questions[thread.id] ?? []).isEmpty
        let isOpen = side.shownSubThread == thread.id
        return Button {
            open(thread.id, here: NSEvent.modifierFlags.contains(.command))
        } label: {
            HStack(spacing: NookTheme.Spacing.md) {
                if asks {
                    Image(icon: "questionmark.bubble").font(NookTheme.font(11, .semibold)).foregroundStyle(NookTheme.iris)
                } else if thread.status.isActive {
                    ProgressView().controlSize(.mini).frame(width: 12)
                } else {
                    Image(icon: Self.symbol(thread.status)).font(NookTheme.font(11, .semibold))
                        .foregroundStyle(thread.status == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                        .frame(width: 12)
                }
                Text(tr("ws.subthread.strip")).foregroundStyle(NookTheme.textTertiary)
                Text(thread.title)
                    .foregroundStyle(NookTheme.paper.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if asks {
                    Text(tr("ws.subthread.asks")).foregroundStyle(NookTheme.iris)
                } else if let state = Self.stateKey(thread.status) {
                    Text(tr(state)).foregroundStyle(thread.status == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                }
                stats(thread)
                if width == 0 || width >= SubThreadStats.providerWidth {
                    Text(thread.provider.displayName).foregroundStyle(NookTheme.textTertiary).lineLimit(1).fixedSize()
                }
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textSecondary)
            .padding(.horizontal, NookTheme.Spacing.xs)
            .padding(.vertical, NookTheme.Spacing.xxs)
            .roundedBackground(isOpen ? NookTheme.rowHover : Color.clear, radius: NookTheme.Radius.chip)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tr(isOpen ? "ws.subthread.close" : side.subThreadRoom ? "ws.subthread.open" : "ws.subthread.openHere"))
        .accessibilityAddTraits(isOpen ? .isSelected : [])
        .contextMenu {
            if side.subThreadRoom {
                Button(tr(isOpen ? "ws.subthread.close" : "ws.subthread.openBeside")) { open(thread.id, here: false) }
            }
            Button(tr("ws.subthread.openHere")) { open(thread.id, here: true) }
        }
    }

    /// What it did so far: the lines it changed, as the agents list and the Changes panel count them (the number of
    /// files on hover, or alone when no lines were counted), and how long it has worked: counting up while it works,
    /// its total once it ended.
    private func stats(_ thread: WorkspaceRun) -> some View {
        let added = thread.changedLinesAdded ?? 0, removed = thread.changedLinesRemoved ?? 0
        let files = thread.changedFiles ?? 0
        return HStack(spacing: NookTheme.Spacing.sm) {
            if added + removed > 0 {
                PullRequestLineCounts(additions: added, deletions: removed, font: NookTheme.mono(10.5))
                    .help(tr("ws.subthread.changes", added, removed, files))
            } else if files > 0 {
                Text(tr("ws.subthread.files", files)).foregroundStyle(NookTheme.textTertiary).fixedSize()
            }
            if thread.status.isActive {
                TimelineView(.nookTicks(every: 1)) { context in
                    duration(thread, now: context.date)
                }
            } else {
                duration(thread, now: Date())
            }
        }
    }

    private func duration(_ thread: WorkspaceRun, now: Date) -> some View {
        let worked = SubThreadStats.worked(started: thread.createdAt, lastStep: workspace.timeline(thread.id).last?.date,
                                           active: thread.status.isActive, now: now)
        return Text(SubThreadStats.clockText(worked))
            .font(NookTheme.mono(10.5))
            .foregroundStyle(NookTheme.textTertiary)
            .monospacedDigit()
            .fixedSize()
            .help(tr(thread.status.isActive ? "ws.subthread.working" : "ws.subthread.worked", SubThreadStats.clockText(worked)))
    }

    /// Beside the main thread, or (`here`, or without room beside it) in its place.
    private func open(_ id: UUID, here: Bool) {
        switch SubThreadBeside.action(for: id, shown: side.shownSubThread, hasRoom: side.subThreadRoom, here: here) {
        case .beside(let id): side.showSubThread(id)
        case .close: side.showSubThread(nil)
        case .here(let id): app.viewModel.selectedAgentID = "run:" + id.uuidString
        }
    }

    private static func symbol(_ status: RunStatus) -> String {
        switch status {
        case .failed: return "xmark.circle"
        case .stopped: return "stop.circle"
        case .completed, .preparing, .running, .waitingApproval: return "checkmark.circle"
        }
    }

    /// What an ended task says beside its title; nil while it works.
    private static func stateKey(_ status: RunStatus) -> String? {
        switch status {
        case .completed: return "ws.subthread.done"
        case .failed: return "ws.subthread.failed"
        case .stopped: return "ws.subthread.stopped"
        case .preparing, .running, .waitingApproval: return nil
        }
    }
}
