import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Notch cards for questions that do not live in the chat (looking at the screen).
extension AppModel {
    /// A question that is answered as a notch card instead of in the chat (looking at the screen, thinking along).
    /// It goes through the same preparation as a chat answer (`prepareRun`): the same scoped, ledger-recorded tools,
    /// the same context, the same action checks and citations. Only the presentation differs.
    func runBrain(userText: String, snapshot: ScreenSnapshot?, silentIfNone: Bool, context: String?, ownRequest: Bool = false) async {
        var sources: [String] = []
        if let snapshot { sources.append(snapshot.windowTitle == "alle zichtbare vensters" ? "schermen" : snapshot.windowTitle) }
        let ledger = RetrievalLedger()
        let prepared = await prepareRun(text: userText, scope: .automatic, snapshotText: snapshot?.text, ledger: ledger, prefetch: false)
        sources.append(contentsOf: connectors.contributingTitles.prefix(4))
        do {
            var plan = try await brain.run(
                userText: userText,
                followUp: false,
                context: prepared.context,
                untrustedLabel: snapshot.map { "\($0.appName) — \($0.windowTitle)" },
                untrusted: snapshot?.text,
                tools: prepared.tools,
                ownRequest: ownRequest,
                onText: silentIfNone ? nil : { [weak self] text in self?.showStreaming(text, sources: sources) }
            )
            // Follow-up actions suggested by Nook appear as interactive buttons below response.
            let split = FollowUps.split(plan.text)
            plan.text = Citations.sanitize(split.body, valid: Set(ledger.references.map(\.number)))
            // The same checks as in the chat: inputs are normalized to the tool's schema, and a step that can never run is dropped.
            plan.actions = plan.actions.compactMap { action in
                guard let spec = prepared.tools.first(where: { $0.name == action.tool }) ?? allTools.first(where: { $0.name == action.tool }) else { return nil }
                var copy = action
                copy.input = ActionGate.normalized(action.input, schema: spec.schema)
                return copy
            }
            plan.actions = withHabits(plan.actions, tools: prepared.tools).actions

            let bare = plan.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
            if plan.actions.isEmpty && bare == "NONE" {
                if silentIfNone {
                    viewModel.dismissCard(id: "thinking")
                } else {
                    replaceThinking(with: answerCard(tr("app.look.nothing")))
                }
                return
            }

            // A look at the screen is always shown first: the plan came from what is on screen, not from the user's words.
            if !silentIfNone, canRunWithoutAsking(plan, request: nil) {
                speakIfAsked(plan.text.isEmpty ? tr("app.done") : plan.text)
                viewModel.removePending(id: "thinking")
                execute(plan)
                return
            }

            if !silentIfNone {
                speakIfAsked(plan.text.isEmpty ? tr("app.plan.ready") : plan.text)
            }
            var card = planCard(plan, context: context, offers: split.offers)
            card.sources = sources
            if silentIfNone {
                viewModel.present(card)
            } else {
                replaceThinking(with: card)
            }
        } catch {
            if !silentIfNone {
                spokenRequest = false
                replaceThinking(with: errorCard(error.localizedDescription))
            }
        }
    }

    /// Response streams in real-time. As text wraps to new lines, the card expands.
    func showStreaming(_ text: String, sources: [String]) {
        let body = FollowUps.streamingBody(text)
        guard !body.isEmpty else { return }
        guard case .card(let shown) = viewModel.state, shown.id == "thinking" else { return }
        let lines = min(9, max(1, Int(ceil(Double(body.count) / (body.count > 140 ? 62.0 : 46.0)))))
        var card = shown
        card.title = String(body.prefix(4000))
        card.context = "Nook"
        card.sources = sources
        card.contentHeight = max(shown.contentHeight, 110 + CGFloat(lines) * (body.count > 140 ? 21 : 24))
        if card.contentHeight != shown.contentHeight {
            viewModel.show(.card(card))
        } else {
            viewModel.updateCard(card)
        }
    }

    func speakIfAsked(_ text: String) {
        defer { spokenRequest = false }
        guard spokenRequest, settings.speakAnswers else { return }
        speech.speak(text, language: settings.language)
    }

    func replaceThinking(with card: NookCard) {
        if case .card(let shown) = viewModel.state, shown.id == "thinking" {
            viewModel.show(.card(card))
        } else {
            // An urgent agent prompt may have dismissed the thinking card; do not re-present.
            viewModel.removePending(id: "thinking")
            viewModel.present(card)
        }
    }
}
