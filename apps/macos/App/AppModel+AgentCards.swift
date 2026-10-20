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

    /// A permission request, the same for terminal sessions and sessions Nook runs: a notch card, or a macOS notification
    /// when you chose those in Settings › Notifications (a click on it, or Show, brings up the card).
    func presentApprovalCard(_ approval: AgentApproval, context: String, open: (label: String, action: () -> Void)?) {
        guard settings.noticeDelivery == .system else {
            showApprovalCard(approval, context: context, open: open)
            return
        }
        NookSound.play(.attention)
        SystemNotifier.shared.approval(
            approval, context: context,
            decide: { [weak self] decision in self?.approvals.decide(approval, decision) },
            show: { [weak self] in self?.showApprovalCard(approval, context: context, open: open) },
            fallback: { [weak self] in self?.showApprovalCard(approval, context: context, open: open, sound: false) }
        )
    }

    /// The notch card for a permission request. The whole command is on the card (scrolled when long), so what you allow
    /// is what you saw.
    private func showApprovalCard(_ approval: AgentApproval, context: String, open: (label: String, action: () -> Void)?,
                                  sound: Bool = true) {
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
        if sound { NookSound.play(.attention) }
    }

    /// Interactive multiple-choice prompts from an agent. Returns collected answers upon completion.
    func presentQuestion(_ request: AgentQuestionRequest, index: Int = 0, selections: [[String]] = [], inNotch: Bool = false) {
        guard index < request.items.count else { return }
        let item = request.items[index]
        let token = "question-" + request.id
        // As a macOS notification: the choices do not fit on a banner, so a click brings up the card.
        if index == 0, !inNotch, settings.noticeDelivery == .system {
            NookSound.play(.attention)
            let show: () -> Void = { [weak self] in self?.presentQuestion(request, inNotch: true) }
            SystemNotifier.shared.notice(id: token, title: tr("noticeDelivery.question", request.agentName),
                                         subtitle: request.project, body: item.question, open: show, fallback: show)
            return
        }
        let choiceID = "\(token)#choice\(index)"

        viewModel.registerChoice(choiceID) { [weak self] labels in
            guard let self else { return }
            let all = selections + [labels]
            if index + 1 < request.items.count {
                self.presentQuestion(request, index: index + 1, selections: all, inNotch: true)
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
        SystemNotifier.shared.withdraw(token)
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
        // While you share your screen or sit in a meeting and chose quiet: the Agents tab shows it, no card pops up.
        guard !quiet.silent else { return }
        if settings.noticeDelivery == .system {
            let open: () -> Void = { [weak self] in
                self?.viewModel.selectedAgentID = session.id
                self?.viewModel.show(.panel(.agents))
            }
            SystemNotifier.shared.notice(
                id: "agentstatus-" + UUID().uuidString, title: tr("agentNotice.compact.\(Self.noticeKey(session.status))", session.name),
                subtitle: session.project, body: session.summary, open: open,
                fallback: { [weak self] in self?.showAgentNotice(session) }
            )
            return
        }
        showAgentNotice(session)
    }

    /// The notch notice for an agent that is done, failed or waits: a card or one slim line (Settings › Notifications).
    private func showAgentNotice(_ session: AgentSession) {
        switch viewModel.state {
        case .idle, .music, .track, .done, .nudge, .moment: break
        case .card(let shown) where shown.id.hasPrefix("agentstatus-"): break
        default: return
        }

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
        // Compact: one line under the notch, with View and OK. The summary waits in the Agents tab.
        if settings.agentNotice == .compact {
            let who = tr("agentNotice.compact.\(Self.noticeKey(session.status))", session.name)
            let message = session.project.isEmpty ? who : who + " · " + session.project
            viewModel.finish(message, button: tr("button.view"), tone: Self.doneTone(session.status), acknowledge: true) { [weak self] in
                self?.viewModel.selectedAgentID = session.id
                self?.viewModel.show(.panel(.agents))
            }
            return
        }

        let token = "agentstatus-" + UUID().uuidString
        let title = session.summary.isEmpty ? fallback : session.summary

        viewModel.register("\(token)#view") { [weak self] in
            self?.viewModel.selectedAgentID = session.id
            self?.viewModel.show(.panel(.agents))
        }
        viewModel.register("\(token)#terminal") { [weak self] in self?.openTerminal(for: session) }
        // OK: gone at once instead of waiting out the timeout; a queued card comes next.
        viewModel.register("\(token)#ok") { [weak self] in self?.viewModel.dismissCard(id: token) }

        var context = "\(session.name) · \(session.project) · \(state)"
        if session.linesAdded + session.linesRemoved > 0 {
            context += " · +\(session.linesAdded) −\(session.linesRemoved)"
        }
        let lines = max(1, min(4, Int(ceil(Double(title.count) / 46.0))))
        let ok = CardAction(label: tr("button.ok"), outcome: .callback("\(token)#ok", ""))
        let card = NookCard(
            id: token,
            mood: mood,
            context: context,
            title: title,
            detail: .none,
            primary: CardAction(label: tr("button.view"), outcome: .callback("\(token)#view", ""), symbol: "eye"),
            secondary: CardAction(label: tr("app.agent.openApp", TerminalLauncher.name(for: session.hostBundleID)),
                                  outcome: .callback("\(token)#terminal", ""), symbol: "terminal"),
            contentHeight: 100 + CGFloat(lines) * 24,
            acknowledge: ok,
            countdown: Self.agentNoticeSeconds,
            escape: ok
        )
        viewModel.show(.card(card))
        dismissAgentCardLater(token)
    }

    /// How long an agent notice stays while the pointer is off the notch; the ring on its OK counts down the same time.
    static let agentNoticeSeconds: TimeInterval = 5.2

    /// Closes an agent notice once it has been shown `agentNoticeSeconds` with the pointer off the notch, like its
    /// countdown ring. Hovering holds the clock, for at most about 100 seconds in all.
    func dismissAgentCardLater(_ token: String) {
        let seconds = Self.agentNoticeSeconds
        Task { [weak self] in
            let step: TimeInterval = 0.1
            var left = seconds
            for _ in 0..<1000 {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                guard let self, case .card(let shown) = self.viewModel.state, shown.id == token else { return }
                if !self.viewModel.pointerInside { left -= step }
                if left <= 0 { break }
            }
            guard let self, case .card(let shown) = self.viewModel.state, shown.id == token else { return }
            self.viewModel.dismissCard(id: token)
        }
    }

    /// The text key part for a notice: done, failed, or waiting on you.
    static func noticeKey(_ status: AgentStatus) -> String {
        switch status {
        case .done: return "done"
        case .failed: return "failed"
        default: return "waiting"
        }
    }

    /// The mark on the compact strip: a check, an hourglass, or an exclamation mark.
    static func doneTone(_ status: AgentStatus) -> DoneTone {
        switch status {
        case .done: return .done
        case .failed: return .failed
        default: return .waiting
        }
    }

    /// Activates the window running this agent.
    func openTerminal(for session: AgentSession) {
        if !TerminalLauncher.activate(sessionBundleID: session.hostBundleID) {
            viewModel.present(errorCard(tr("app.agent.noTerminal", session.name)))
        }
    }
}
