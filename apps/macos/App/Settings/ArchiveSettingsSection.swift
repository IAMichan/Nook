import SwiftUI

/// Settings › Agents › Archive: everything put away in one place, newest first, each with Unarchive and
/// Delete. Coding agent sessions first, then Nook's own conversations. A search narrows both lists once they grow, and
/// each list ends in "Delete all archived…" (what the search found, while searching), asked once with the count.
struct ArchiveSettingsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var query = ""

    var body: some View {
        ArchiveLists(workspace: app.workspace, chat: app.chat, query: $query)
    }
}

/// The two lists, watching the stores they show, so unarchiving or deleting updates the page at once.
private struct ArchiveLists: View {
    @ObservedObject var workspace: WorkspaceManager
    @ObservedObject var chat: NookChat
    @Binding var query: String

    var body: some View {
        let sessions = ArchivePurge.shown(workspace.runs, query: query, archived: \.archived,
                                          fields: { [$0.title, $0.projectPath] }, updated: \.updatedAt)
        let conversations = ArchivePurge.shown(chat.conversations, query: query, archived: \.archived,
                                               fields: { [$0.title] }, updated: \.updated)
        // "Delete all archived…" goes the same way as a row's Delete, so each session's worktree follows the cleanup
        // rules, and it never takes a session or conversation that still works.
        let deletableSessions = ArchivePurge.deletable(sessions, busy: sessionBusy).map(\.id)
        let deletableConversations = ArchivePurge.deletable(conversations, busy: \.busy).map(\.id)
        Section {
            NookSearchField(prompt: tr("settings.archive.search"), text: $query, style: .inline)
        }
        Section {
            if sessions.isEmpty {
                ListEmptyNote(tr("settings.archive.noSessions"))
            }
            ForEach(sessions) { run in
                ArchiveRow(title: run.title.isEmpty ? run.task : run.title,
                           detail: URL(fileURLWithPath: run.projectPath).lastPathComponent,
                           date: run.updatedAt,
                           agent: run.provider.kind,
                           busy: sessionBusy(run),
                           unarchive: { workspace.setArchived(run.id, false) },
                           delete: { workspace.delete(run.id) })
            }
            if !deletableSessions.isEmpty {
                DeleteAllArchived(count: deletableSessions.count, searching: !query.isEmpty,
                                  question: tr("settings.archive.deleteSessions.confirm", deletableSessions.count),
                                  detail: tr("settings.archive.deleteSessions.detail")) {
                    for id in deletableSessions { workspace.delete(id) }
                }
            }
        } header: {
            SettingText("settings.archive.sessions")
        }
        Section {
            if conversations.isEmpty {
                ListEmptyNote(tr("settings.archive.noConversations"))
            }
            ForEach(conversations) { conversation in
                ArchiveRow(title: conversation.title, detail: nil, date: conversation.updated, agent: nil,
                           busy: conversation.busy,
                           unarchive: { chat.setArchived(false, conversation.id) },
                           delete: { chat.delete([conversation.id]) })
            }
            if !deletableConversations.isEmpty {
                DeleteAllArchived(count: deletableConversations.count, searching: !query.isEmpty,
                                  question: tr("settings.archive.deleteConversations.confirm", deletableConversations.count),
                                  detail: tr("settings.archive.deleteConversations.detail")) {
                    chat.delete(Set(deletableConversations))
                }
            }
        } header: {
            SettingText("settings.archive.conversations")
        }
    }

    /// A session that still works: a running turn, or a process Nook keeps alive. `WorkspaceManager.delete` refuses it.
    private func sessionBusy(_ run: WorkspaceRun) -> Bool {
        run.status.isActive || workspace.isRunning(run.id)
    }
}

/// The foot of an archive list: one button that deletes everything the list shows (with a search, what it found),
/// after one confirmation that states how many go.
private struct DeleteAllArchived: View {
    let count: Int
    let searching: Bool
    let question: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            ConfirmedButton(question: question, detail: detail, confirmTitle: tr("button.delete"), action: action) {
                Text(searching ? tr("settings.archive.deleteFound", count) : tr("settings.archive.deleteAll"))
            }
            .controlSize(.small)
        }
    }
}

/// One archived item: its agent's logo for a session, its title and where it was, when it was last used, and the two
/// ways out of the archive.
private struct ArchiveRow: View {
    let title: String
    let detail: String?
    let date: Date
    let agent: AgentKind?
    /// Still working: it cannot be deleted until it stops.
    let busy: Bool
    let unarchive: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: NookTheme.Spacing.md) {
            if let agent {
                LogoImage.agent(agent)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title).lineLimit(1)
                Text([detail, date.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }.joined(separator: " · "))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: NookTheme.Spacing.md)
            Button(tr("select.unarchive"), action: unarchive)
                .controlSize(.small)
            ConfirmedButton(symbol: "trash", title: tr("button.delete"), question: tr("confirm.deleteChat", title),
                            action: delete)
                .buttonStyle(.borderless)
                .help(tr("button.delete"))
                .accessibilityLabel(tr("button.delete"))
                .disabled(busy)
        }
    }
}
