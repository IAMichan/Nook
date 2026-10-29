import SwiftUI

/// The notice a coding agent gives by itself (done, failed, waiting on you), built once for every agent: a terminal
/// session and a session Nook runs fill in an `AgentStatusNotice` and hand it here, so the card, the strip, the sound and the
/// entry under the bell look and behave the same whichever agent it is.
extension AppModel {
    /// How long an agent notice stays while the pointer is off the notch; the ring on its OK counts down the same time.
    static let agentNoticeSeconds: TimeInterval = 5.2

    /// Keeps the notice under the bell and shows it the way Settings › Notifications says for agents. `open` is what
    /// View does (the session in the panel or the main window); `openApp` the second button, where the agent has one
    /// (its terminal). A notice that waits on you always reaches you (`NoticePacer`).
    func deliverAgentNotice(_ notice: AgentStatusNotice, app: String, target: NoticeEntry.Target, watching: Bool = false,
                            open: @escaping () -> Void, openApp: (title: String, action: () -> Void)? = nil) {
        logNotice(Self.noticeKind(notice.state), title: notice.headline,
                  detail: notice.summary.isEmpty ? AgentStatusNotice.short(notice.topic) : notice.summary, context: notice.project,
                  target: target, source: .agents, app: app)
        deliverNotice(.agents, app: app, id: "agentstatus-" + UUID().uuidString, pace: notice.pace,
                      urgent: notice.state == .waiting, title: notice.headline, subtitle: notice.project,
                      body: notice.summary, sound: Self.noticeSound(notice.state), watching: watching,
                      kind: Self.toastKind(notice.state),
                      card: { [weak self] in self?.showAgentNotice(notice, open: open, openApp: openApp) },
                      strip: { [weak self] in self?.showAgentStrip(notice, open: open) },
                      open: open)
    }

    /// The card: the agent's logo, who and where, its state and changed lines in the header; what the session is about
    /// as the title, and what the agent said last under it. View, the agent's own app, and OK with its countdown.
    private func showAgentNotice(_ notice: AgentStatusNotice, open: @escaping () -> Void,
                                 openApp: (title: String, action: () -> Void)?) {
        guard notchFreeForNotice else { return }
        let token = "agentstatus-" + UUID().uuidString
        viewModel.register("\(token)#view", open)
        if let openApp { viewModel.register("\(token)#app", openApp.action) }
        // OK: gone at once instead of waiting out the timeout; a queued card comes next.
        viewModel.register("\(token)#ok") { [weak self] in self?.viewModel.dismissCard(id: token) }

        let tone = Self.doneTone(notice.state)
        let titleLines = max(1, min(2, Int(ceil(Double(notice.title.count) / 40.0))))
        let detailLines = notice.detail.map { max(1, min(3, Int(ceil(Double($0.count) / 58.0)))) } ?? 0
        let ok = CardAction(label: tr("button.ok"), outcome: .callback("\(token)#ok", ""))
        viewModel.show(.card(NookCard(
            id: token,
            mood: tone.mood,
            context: notice.context,
            agent: notice.agent,
            title: notice.title,
            detail: notice.detail.map { .summary($0) } ?? .none,
            primary: CardAction(label: tr("button.view"), outcome: .callback("\(token)#view", ""), symbol: "eye"),
            secondary: openApp.map { CardAction(label: $0.title, outcome: .callback("\(token)#app", ""), symbol: "terminal") }
                ?? CardAction(label: "", outcome: .dismiss),
            contentHeight: 96 + CGFloat(titleLines) * 26 + CGFloat(detailLines) * 20,
            acknowledge: ok,
            countdown: Self.agentNoticeSeconds,
            escape: ok,
            status: CardStatus(text: tr("card.status.\(notice.state.rawValue)"), tone: tone),
            changes: notice.hasChanges ? LineChanges(added: notice.added, removed: notice.removed) : nil
        )))
        dismissAgentCardLater(token)
    }

    /// One line in the notch's own row: the agent's logo with its state as a badge, the headline and the project, View
    /// and OK. What it said waits in the session.
    private func showAgentStrip(_ notice: AgentStatusNotice, open: @escaping () -> Void) {
        guard notchFreeForNotice else { return }
        let message = notice.project.isEmpty ? notice.headline : notice.headline + " · " + notice.project
        viewModel.finish(message, button: tr("button.view"), tone: Self.doneTone(notice.state), inline: true,
                         agent: notice.agent, action: open)
    }

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

    /// What an agent notice is about for `NoticePacer`: its session, and a failure apart, so a session that ends in an
    /// error right after a finished turn still tells you.
    static func agentPace(_ id: String, failed: Bool) -> String {
        "agent:" + id + (failed ? ":failed" : "")
    }

    /// What a permission request or an agent's question counts as for `NoticePacer`: it never waits, but what comes
    /// after it does.
    static let urgentPace = "urgent"

    /// The history's state for an agent notice.
    static func noticeKind(_ state: AgentStatusNotice.State) -> NoticeEntry.Kind {
        switch state {
        case .done: return .done
        case .failed: return .failed
        case .waiting: return .waiting
        }
    }

    /// The mark and color of an agent notice: a check in mint, a bubble in amber, an exclamation mark in coral.
    static func doneTone(_ state: AgentStatusNotice.State) -> DoneTone {
        switch state {
        case .done: return .done
        case .failed: return .failed
        case .waiting: return .waiting
        }
    }

    static func noticeSound(_ state: AgentStatusNotice.State) -> NookSound {
        switch state {
        case .done: return .done
        case .failed: return .error
        case .waiting: return .attention
        }
    }

    static func toastKind(_ state: AgentStatusNotice.State) -> NookToastKind {
        switch state {
        case .done: return .success
        case .failed: return .error
        case .waiting: return .warning
        }
    }
}
