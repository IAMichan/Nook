import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Cards for coding agents: approvals, questions and status.
extension AppModel {
    // MARK: Agents

    func presentApproval(_ request: ApprovalRequest) {
        let token = "approval-" + request.id
        let danger = request.assessment.level == .danger
        let id = request.id

        viewModel.register("\(token)#yes") { [weak self] in self?.hub.decide(id, .allow) }
        viewModel.register("\(token)#always") { [weak self] in self?.hub.decide(id, .always) }
        viewModel.register("\(token)#no") { [weak self] in self?.hub.decide(id, .deny) }
        viewModel.register("\(token)#terminal") { [weak self] in
            guard let self else { return }
            let host = self.hub.sessions.first { $0.id == request.sessionKey }?.hostBundleID
            self.hub.decide(id, .terminal)
            TerminalLauncher.activate(sessionBundleID: host)
        }

        var context = "\(request.agentName) · \(request.project)"
        let others = hub.approvals.count - 1
        if others > 0 { context += " · nog \(others) wachtend" }

        let detail: CardDetail
        let height: CGFloat
        if request.diff.isEmpty {
            detail = .command(String(request.summary.prefix(20_000)), note: request.assessment.note)
            height = 214
        } else {
            detail = .diff(title: request.summary, lines: request.diff, note: request.assessment.note)
            height = 150 + min(166, CGFloat(request.diff.count) * 15 + 34)
        }

        var extra = [CardAction(label: "In terminal", outcome: .callback("\(token)#terminal", ""))]
        if request.canAlways {
            extra.insert(CardAction(label: "Altijd", outcome: .callback("\(token)#always", "")), at: 0)
        }

        let card = NookCard(
            id: token,
            mood: danger ? .worry : .waiting,
            context: context,
            title: request.title,
            detail: detail,
            primary: CardAction(label: "Toestaan", outcome: .callback("\(token)#yes", "")),
            secondary: CardAction(label: "Weigeren", outcome: .callback("\(token)#no", "")),
            contentHeight: height,
            extra: extra,
            urgent: true
        )
        viewModel.presentUrgent(card)
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
            primary: CardAction(label: "In terminal", outcome: .callback("\(token)#terminal", "")),
            secondary: CardAction(label: "", outcome: .dismiss),
            contentHeight: min(470, 110 + CGFloat(titleLines) * 24 + optionsHeight + (item.multiSelect ? 52 : 0)),
            urgent: true
        )
        if index == 0 {
            viewModel.presentUrgent(card)
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
        switch viewModel.state {
        case .idle, .music, .track, .done, .nudge: break
        case .card(let shown) where shown.id.hasPrefix("agentstatus-"): break
        default: return
        }

        let token = "agentstatus-" + UUID().uuidString
        let mood: NookMood
        let state: String
        let fallback: String
        switch session.status {
        case .done:
            mood = .done; state = "klaar"; fallback = "Klaar met je opdracht."
        case .failed:
            mood = .worry; state = "liep vast"; fallback = "Er ging iets mis."
        default:
            mood = .waiting; state = "wacht op je"; fallback = "Wacht op je antwoord in de terminal."
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
            primary: CardAction(label: "Bekijk", outcome: .callback("\(token)#view", "")),
            secondary: CardAction(label: "Open \(TerminalLauncher.name(for: session.hostBundleID))", outcome: .callback("\(token)#terminal", "")),
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
            viewModel.present(errorCard("Ik vind de terminal van \(session.name) niet. Staat hij nog open?"))
        }
    }
}
