import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Cards for coding agents: approvals, questions and status.
extension AppModel {
    // MARK: Agents

    func presentApproval(_ request: ApprovalRequest) {
        var context = "\(request.agentName) · \(request.project)"
        let others = hub.approvals.count - 1
        if others > 0 { context += " · nog \(others) wachtend" }
        presentApprovalCard(ApprovalCenter.make(request), context: context, open: nil)
    }

    /// The notch card for a permission request, the same for terminal sessions and sessions Nook runs. The whole command
    /// is on the card (scrolled when long), so what you allow is what you saw.
    func presentApprovalCard(_ approval: AgentApproval, context: String, open: (label: String, action: () -> Void)?) {
        let token = approval.cardToken
        viewModel.register("\(token)#yes") { [weak self] in self?.approvals.decide(approval, .allow) }
        viewModel.register("\(token)#always") { [weak self] in self?.approvals.decide(approval, .always) }
        viewModel.register("\(token)#no") { [weak self] in self?.approvals.decide(approval, .deny) }
        viewModel.register("\(token)#terminal") { [weak self] in
            guard let self, case .hook(let requestID) = approval.origin else { return }
            let host = self.hub.sessions.first { $0.approvalID == requestID }?.hostBundleID
            self.approvals.decide(approval, .terminal)
            TerminalLauncher.activate(sessionBundleID: host)
        }
        viewModel.register("\(token)#open") { open?.action() }

        let detail: CardDetail
        let height: CGFloat
        if approval.diff.isEmpty {
            detail = .command(approval.command, note: approval.note)
            height = 214
        } else {
            detail = .diff(title: approval.command, lines: approval.diff, note: approval.note)
            height = 150 + min(166, CGFloat(approval.diff.count) * 15 + 34)
        }

        var extra: [CardAction] = []
        if approval.canTerminal { extra.append(CardAction(label: tr("approval.inTerminal"), outcome: .callback("\(token)#terminal", ""))) }
        if let open { extra.append(CardAction(label: open.label, outcome: .callback("\(token)#open", ""))) }
        if approval.canAlways { extra.insert(CardAction(label: tr("button.always"), outcome: .callback("\(token)#always", "")), at: 0) }

        let card = NookCard(
            id: token,
            mood: approval.danger ? .worry : .waiting,
            context: context,
            title: approval.title,
            detail: detail,
            primary: CardAction(label: tr("button.allow"), outcome: .callback("\(token)#yes", "")),
            secondary: CardAction(label: tr("button.deny"), outcome: .callback("\(token)#no", "")),
            contentHeight: height,
            extra: extra,
            urgent: true
        )
        viewModel.presentUrgent(card, keepPanel: true)
        NookSound.play(.attention)
    }

    /// Interactive multiple-choice prompts from an agent. Returns collected answers upon completion.
    func presentQuestion(_ request: AgentQuestionRequest, index: Int = 0, selections: [[String]] = []) {
        guard index < request.items.count else { return }
        let item = request.items[index]
        let token = "question-" + request.id
        let choiceID = "\(token)#choice\(index)"

        viewModel.registerChoice(choiceID) { [weak self] labels in
            guard let self else { return }
            let all = selections + [labels]
            if index + 1 < request.items.count {
                self.presentQuestion(request, index: index + 1, selections: all)
            } else {
                self.hub.answerQuestion(request.id, selections: all)
            }
        }
        viewModel.register("\(token)#terminal") { [weak self] in
            guard let self else { return }
            let host = self.hub.sessions.first { $0.id == request.sessionKey }?.hostBundleID
            self.hub.answerQuestionInTerminal(request.id)
            TerminalLauncher.activate(sessionBundleID: host)
        }

        var context = "\(request.agentName) · \(request.project) vraagt"
        if !item.header.isEmpty { context += " · \(item.header)" }
        if request.items.count > 1 { context += " · \(index + 1) van \(request.items.count)" }

        let titleLines = max(1, Int(ceil(Double(item.question.count) / 46.0)))
        let optionsHeight = item.options.reduce(CGFloat(0)) { $0 + ($1.description.isEmpty ? 40 : 58) }
        let card = NookCard(
            id: token,
            mood: .waiting,
            context: context,
            title: item.question,
            detail: .choices(ChoiceSet(
                id: choiceID,
                options: item.options.map { ChoiceOption(label: $0.label, description: $0.description) },
                multiSelect: item.multiSelect
            )),
            primary: CardAction(label: tr("approval.inTerminal"), outcome: .callback("\(token)#terminal", "")),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: min(470, 110 + CGFloat(titleLines) * 24 + optionsHeight + (item.multiSelect ? 52 : 0)),
            urgent: true
        )
        if index == 0 {
            // An open panel stays: it asks in its own compact bar (see `PanelApprovalBar`).
            viewModel.presentUrgent(card, keepPanel: true)
            NookSound.play(.attention)
        } else {
            viewModel.show(.card(card))
        }
    }

    /// Agent question handled: dismisses card and provides brief confirmation if answered in Nook.
    func cardGone(_ token: String, message: String?) {
        var visible = false
        if case .card(let shown) = viewModel.state, shown.id == token { visible = true }
        viewModel.dismissCard(id: token)
        guard visible, let message else { return }
        if case .card = viewModel.state { return }   // next question is already queued
        viewModel.finish(message)
    }

    /// Agent finished, failed, or awaiting input: dedicated notification card with agent message.
    /// Displayed unless user is active in notch; auto-dismisses after a short timeout.
    func agentNeedsAttention(_ session: AgentSession) {
        NookSound.play(session.status == .done ? .done : .attention)
        // The last agent finished: a small celebration.
        if session.status == .done {
            let others = activeAgents.contains { $0.id != session.id }
            if others { NookPresence.shared.nod() } else { NookPresence.shared.celebrate() }
            buddyAgentFinished(last: !others)
        }
        switch viewModel.state {
        case .idle, .music, .track, .done, .nudge, .moment: break
        case .card(let shown) where shown.id.hasPrefix("agentstatus-"): break
        default: return
        }

        let token = "agentstatus-" + UUID().uuidString
        let mood: NookMood
        let state: String
        let fallback: String
        switch session.status {
        case .done:
            mood = .done; state = tr("app.agent.done.state"); fallback = tr("app.agent.done.fallback")
        case .failed:
            mood = .worry; state = tr("app.agent.failed.state"); fallback = tr("app.agent.failed.fallback")
        default:
            mood = .waiting; state = tr("app.agent.waiting.state"); fallback = tr("app.agent.waiting.fallback")
        }
        let title = session.summary.isEmpty ? fallback : session.summary

        viewModel.register("\(token)#view") { [weak self] in
            self?.viewModel.selectedAgentID = session.id
            self?.viewModel.show(.panel(.agents))
        }
        viewModel.register("\(token)#terminal") { [weak self] in self?.openTerminal(for: session) }

        var context = "\(session.name) · \(session.project) · \(state)"
        if session.linesAdded + session.linesRemoved > 0 {
            context += " · +\(session.linesAdded) −\(session.linesRemoved)"
        }
        let lines = max(1, min(4, Int(ceil(Double(title.count) / 46.0))))
        let card = NookCard(
            id: token,
            mood: mood,
            context: context,
            title: title,
            detail: .none,
            primary: CardAction(label: tr("button.view"), outcome: .callback("\(token)#view", "")),
            secondary: CardAction(label: tr("app.agent.openApp", TerminalLauncher.name(for: session.hostBundleID)), outcome: .callback("\(token)#terminal", "")),
            contentHeight: 100 + CGFloat(lines) * 24
        )
        viewModel.show(.card(card))

        // Auto-dismisses after 5 seconds unless hovered.
        Task { [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 5_200_000_000)
                guard let self, case .card(let shown) = self.viewModel.state, shown.id == token else { return }
                if !self.viewModel.pointerInside {
                    self.viewModel.dismissCard(id: token)
                    return
                }
            }
        }
    }

    /// Activates the window running this agent.
    func openTerminal(for session: AgentSession) {
        if !TerminalLauncher.activate(sessionBundleID: session.hostBundleID) {
            viewModel.present(errorCard(tr("app.agent.noTerminal", session.name)))
        }
    }
}
