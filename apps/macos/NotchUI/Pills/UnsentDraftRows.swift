import SwiftUI

/// The new-session drafts you typed in and did not start, at the top of the Agents list, newest first.
/// Each one is drawn as a session row (`AgentRowLayout`): the project on the first line with a quiet
/// "Draft" badge where a session shows its status, and the first line of the words as its name. A click opens the
/// composer on that draft; the × under the pointer throws it away. The draft open in the composer is lit as the open one.
struct UnsentDraftRows: View {
    @ObservedObject private var store = ComposerDraftStore.shared
    /// Whether the new-session composer is what is open now.
    let composerOpen: Bool
    let open: () -> Void

    var body: some View {
        Group { drafts }
            .animation(NookTheme.reveal, value: store.unsentNewSessions.map(\.key))
    }

    @ViewBuilder private var drafts: some View {
        if !store.unsentNewSessions.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                ForEach(store.unsentNewSessions) { draft in
                    UnsentDraftRow(draft: draft, place: placeName(draft.place), placeHelp: placeHelp(draft.place),
                                   selected: composerOpen && store.openNewSession == draft.key) {
                        reopen(draft)
                    } discard: {
                        NewSessionComposer.discardDraft(draft.key)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .transition(.opacity)
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

    private func placeHelp(_ place: NewSessionDraftKey.Place) -> String {
        switch place {
        case .folder(let path): ScratchProjects.isScratch(path) ? "" : AgentPathFormat.tilde(path)
        case .machine: ""
        }
    }
}

private struct UnsentDraftRow: View {
    let draft: UnsentDraft
    let place: String
    let placeHelp: String
    let selected: Bool
    let action: () -> Void
    let discard: () -> Void
    @State private var hovering = false

    /// No fill at rest, as the session rows under it: only the one under the pointer or the open one lifts.
    private var background: Color { NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: action) { content }
                .buttonStyle(.nookPlain)
            if hovering {
                ToolbarIconButton("xmark", tr("inbox.draft.discard"), height: 22, width: 22, discard)
                    .rowActionsBackdrop(background)
                    // Level with the first line, where the badge it replaces sits.
                    .padding(.top, NookTheme.Spacing.md - 1)
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
        AgentRowLayout(folder: place, folderHelp: placeHelp, hasMeta: false) {
            StatusBadgeLabel(word: tr("inbox.draft.unsent"), tint: NookTheme.amber) {
                Image(icon: "pencil")
            }
            .opacity(hovering ? 0 : 1)
        } title: {
            AgentRowTitle(title: draft.preview)
        } logo: {
            EmptyView()
        } meta: {
            EmptyView()
        }
        .padding(.horizontal, NookTheme.Spacing.md + NookTheme.Spacing.xxs)
        .padding(.vertical, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(background, radius: NookTheme.Radius.chip)
        .contentShape(Rectangle())
    }
}
