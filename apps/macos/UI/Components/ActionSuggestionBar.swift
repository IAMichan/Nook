import SwiftUI

/// Above a conversation's field: what Nook could do for what was just said (`ChatActionSuggestion`), such as starting an
/// agent on a task that came up in a chat. One panel for every conversation with a field (a chat of any chat app, an
/// agent's session, Nook Chat) on the composer tray's surface, as its draft under "@nook …" and the other bars above the
/// field are, so it follows the look's colors: the steps, why, Do it, "Adjust first" for a new session, and the cross.
/// It asks for a look whenever the newest message (`turn`) or `busy` changes.
struct ActionSuggestionBar: View {
    /// The conversation's newest message; nil while there is none to read.
    let turn: ChatActionSuggestion.Turn?
    /// Something else has the conversation (an answer under way, Nook's draft in the field): no look meanwhile.
    var busy = false
    /// Where the conversation is, and its newest lines, read only when Nook is about to look.
    let place: ChatActionSuggestion.Place
    let lines: () -> [ChatActionSuggestion.Line]
    /// Runs the steps after your click (`AppModel.runDraftActions`).
    let act: ([PlannedAction]) async -> (results: [String], failure: String?)
    /// Opens a suggested session in the new-session composer (`AppModel.adjustSuggestedAction`).
    var adjust: ((PlannedAction) -> Void)? = nil

    @ObservedObject private var store = ChatActionSuggestions.shared

    /// The step "Adjust first" opens: a new agent session, whose task is worth reading before it starts.
    static let adjustableTool = "start_agent_session"

    private struct Trigger: Equatable {
        var turn: ChatActionSuggestion.Turn?
        var busy: Bool
    }

    var body: some View {
        Group {
            if let conversation = turn?.conversation, let state = store.shown(conversation), state.run == .waiting {
                // Nothing has happened yet: a quiet line that only says what Nook could do.
                WhisperSuggestion(actions: state.actions, reason: state.reason,
                                  perform: { store.run(conversation, act: act) },
                                  dismiss: { store.dismiss(conversation) },
                                  adjust: adjustable(state).map { action in {
                                      store.dismiss(conversation)
                                      adjust?(action)
                                  } })
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let conversation = turn?.conversation, let state = store.shown(conversation) {
                // Running, done or failed: the full card, which shows how it went.
                DraftActions(actions: state.actions, run: state.run,
                             perform: { store.run(conversation, act: act) },
                             dismiss: { store.dismiss(conversation) },
                             title: tr("chats.draft.actionsTitle"), reason: state.reason, standalone: true,
                             adjust: adjustable(state).map { action in {
                                 store.dismiss(conversation)
                                 adjust?(action)
                             } })
                    .padding(NookTheme.Spacing.lg)
                    .cardBackground(NookTheme.composerTray, stroke: NookTheme.fieldStroke, radius: NookTheme.Radius.sheet)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(NookTheme.reveal, value: turn.flatMap { store.shown($0.conversation) })
        .onChange(of: Trigger(turn: turn, busy: busy), initial: true) { _, trigger in
            store.request(trigger.turn, busy: trigger.busy, place: place, lines: lines)
        }
    }

    /// The one step "Adjust first" applies to: a single new session waiting for your click.
    private func adjustable(_ state: ChatActionSuggestions.State) -> PlannedAction? {
        guard adjust != nil, state.run == .waiting, state.actions.count == 1,
              let step = state.actions.first, step.action.tool == Self.adjustableTool else { return nil }
        return step.action
    }
}

/// A suggestion before you act on it: one quiet line on a dashed outline, the way something not yet real looks, so it
/// needs no "nothing happens until…" line. The steps, Do it (and "Adjust first" for a new session), and the cross. On
/// hover it fills in as a card, and why Nook proposes it shows as the line's tip. Running it hands over to the full
/// `DraftActions` card, which shows how it went.
private struct WhisperSuggestion: View {
    let actions: [ChatDraftAction]
    let reason: String?
    let perform: () -> Void
    let dismiss: () -> Void
    var adjust: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: NookTheme.Spacing.sm) {
            Image(icon: "sparkles")
                .font(NookTheme.font(11, .semibold))
                .foregroundStyle(hovering ? NookTheme.iris : NookTheme.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                ForEach(actions) { action in
                    Text(TextKit.droppingRedundantLinks(action.step.text))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(hovering ? NookTheme.textStrong : NookTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .nookTip(reason ?? "")
            if let adjust {
                NookGhostButton(title: tr("suggestActions.adjust"), compact: true, action: adjust)
                    .fixedSize()
            }
            NookGhostButton(title: tr("chats.draft.actions.run"), symbol: "checkmark", compact: true, action: perform)
                .fixedSize()
            ToolbarIconButton("xmark", tr("chats.draft.actions.dismiss"), dismiss)
        }
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.sm)
        .padding(.vertical, NookTheme.Spacing.sm)
        .background(NookTheme.shape(NookTheme.Radius.sheet).fill(hovering ? NookTheme.composerTray : Color.clear))
        .overlay(NookTheme.shape(NookTheme.Radius.sheet)
            .strokeBorder(NookTheme.fieldStroke, style: StrokeStyle(lineWidth: 1, dash: hovering ? [] : [4, 3])))
        .contentShape(NookTheme.shape(NookTheme.Radius.sheet))
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tr("chats.draft.actionsTitle"))
    }
}
