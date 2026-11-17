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
            if let conversation = turn?.conversation, let state = store.shown(conversation) {
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
