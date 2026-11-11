import SwiftUI

/// The new-session drafts you typed in and did not start, on top of the Agents list, newest first, as t3code lists its
/// draft threads: a pen, the project, and the first line of the words. A click opens the composer on that draft; the ×
/// under the pointer throws it away. The draft open in the composer stays in its place, lit as the open one.
struct UnsentDraftRows: View {
    @ObservedObject private var store = ComposerDraftStore.shared
    /// Whether the new-session composer is what is open now.
    let composerOpen: Bool
    let open: () -> Void

    var body: some View {
        if !store.unsentNewSessions.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                ForEach(store.unsentNewSessions) { draft in
                    UnsentDraftRow(draft: draft, place: placeName(draft.place),
                                   selected: composerOpen && store.openNewSession == draft.key) {
                        reopen(draft)
                    } discard: {
                        NewSessionComposer.discardDraft(draft.key)
                    }
                }
            }
            .padding(.bottom, NookTheme.Spacing.xs)
        }
    }

    private func reopen(_ draft: UnsentDraft) {
        switch draft.place {
        case .folder(let path): PromptLinkInbox.shared.requestProject(path)
        case .machine: PromptLinkInbox.shared.requestProject(draft.key)
        }
        open()
    }

    private func placeName(_ place: NewSessionDraftKey.Place) -> String {
        switch place {
        case .folder(let path):
            if ScratchProjects.isScratch(path) { return tr("ws.new.noProject") }
            return (path as NSString).lastPathComponent
        case .machine(let id):
            return RemoteMachines.load().first { $0.id == id }?.name ?? id
        }
    }
}

private struct UnsentDraftRow: View {
    let draft: UnsentDraft
    let place: String
    let selected: Bool
    let action: () -> Void
    let discard: () -> Void
    @State private var hovering = false

    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.plain)
            if hovering {
                ToolbarIconButton("xmark", tr("inbox.draft.discard"), height: 22, width: 22, discard)
                    .rowActionsBackdrop(background)
                    .padding(.top, NookTheme.Spacing.sm)
                    .padding(.trailing, NookTheme.Spacing.md)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(tr("inbox.draft.help", place))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tr("inbox.draft.accessibility", place, draft.preview))
        .accessibilityAction(named: tr("inbox.draft.discard"), discard)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(icon: "square.and.pencil")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.amber)
                Text(place)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(tr("inbox.draft.unsent"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .opacity(hovering ? 0 : 1)
            }
            Text(draft.preview)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .padding(.vertical, NookTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(background, radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
    }
}
