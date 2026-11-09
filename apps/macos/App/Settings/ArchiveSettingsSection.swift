import SwiftUI

/// Settings › Agents › Archive: everything put away in one place, newest first, each with Unarchive and
/// Delete. Coding agent sessions first, then Nook's own conversations. A search narrows both lists once they grow.
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
        let sessions = workspace.runs.filter { $0.archived && matches($0.title, $0.projectPath) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let conversations = chat.conversations.filter { $0.archived && matches($0.title) }
            .sorted { $0.updated > $1.updated }
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
                           unarchive: { workspace.setArchived(run.id, false) },
                           delete: { workspace.delete(run.id) })
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
                           unarchive: { chat.setArchived(false, conversation.id) },
                           delete: { chat.delete(conversation.id) })
            }
        } header: {
            SettingText("settings.archive.conversations")
        }
    }

    private func matches(_ fields: String...) -> Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

/// One archived item: its agent's logo for a session, its title and where it was, when it was last used, and the two
/// ways out of the archive.
private struct ArchiveRow: View {
    let title: String
    let detail: String?
    let date: Date
    let agent: AgentKind?
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
        }
    }
}
