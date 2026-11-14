import SwiftUI

/// What needs you, gathered from every source as `AttentionItem`s and ranked by one `AttentionScorer`: Today (and with it
/// the phone's home), the starter suggestions and the menu bar read these, so they agree on what comes first.
extension AppModel {
    /// One thing that may need you, with how Today shows it.
    struct RankedTodayItem {
        var attention: AttentionItem
        var row: TodayItem
    }

    /// The scorer with what you did with Nook's notices so far.
    func attentionScorer(now: Date = Date()) -> AttentionScorer {
        AttentionScorer(feedback: AttentionFeedbackStore.shared.feedback, now: now)
    }

    /// The agent sessions that need you, by their state in the Agents list (`AgentAttention`): a terminal session that
    /// waits on a permission or a question or failed, and a session Nook runs that waits on you or failed. A session you
    /// marked finished only comes back when it needs you.
    func agentAttention(now: Date = Date()) -> [RankedTodayItem] {
        var result: [RankedTodayItem] = []
        let finished = FinishedSessions.shared
        for session in agentSessions where !session.isDetected {
            let attention: AgentAttention
            if session.approvalID != nil {
                attention = .approval
            } else {
                switch session.status {
                case .waiting: attention = .input
                case .failed: attention = .failed
                default: continue
                }
            }
            guard !(attention == .failed && finished.contains(FinishedSessions.key(session: session))),
                  let item = AttentionItem.agent(id: session.id, app: session.name, attention: attention,
                                                 since: session.updated) else { continue }
            let waiting = attention.needsYou
            result.append(RankedTodayItem(attention: item, row: TodayItem(
                id: "agent-\(session.id)",
                title: waiting ? tr("app.today.agentWaiting", session.name) : tr("app.today.agentFailed", session.name),
                subtitle: session.project,
                action: tr("button.view"),
                color: session.status.color,
                target: .agent(session.id),
                logo: .agent(session.name)
            )))
        }
        for run in workspace.runs where !run.archived {
            let settled = finished.contains(FinishedSessions.key(run: run))
            let attention = workspace.attention(run, unseen: false, settled: settled, now: now)
            // A failed session Nook runs already showed its card; Today keeps only what still waits on you.
            guard attention.needsYou,
                  let item = AttentionItem.agent(id: run.id.uuidString, app: run.provider.rawValue, attention: attention,
                                                 since: run.updatedAt) else { continue }
            let name = run.provider.displayName
            result.append(RankedTodayItem(attention: item, row: TodayItem(
                id: "run-\(run.id.uuidString)",
                title: tr("app.today.agentWaiting", name),
                subtitle: run.title.isEmpty ? (run.projectPath as NSString).lastPathComponent : run.title,
                action: tr("button.view"),
                color: NookTheme.amber,
                target: .action { [weak self] in self?.openWorkspace(run: run.id) },
                logo: .agent(name)
            )))
        }
        return result
    }

    /// The chats you owe a reply (`ChatFollowUps.owed`), every app at once, without hidden or snoozed chats: the first few.
    func owedChatAttention(now: Date = Date(), limit: Int = 3) -> [RankedTodayItem] {
        let inbox = ChatCaptureService.shared.loadedInbox
        let rules = ChatNoticeRulesStore.shared.rules
        let turns = ChatFollowUpStore.turns(of: inbox).filter { !rules.isHidden($0.chat) && rules.mode(for: $0.chat) != .muted }
        return ChatFollowUpStore.shared.follow.owed(turns, now: now).prefix(limit).map { turn in
            let context = inbox.threads[turn.chat].map(Self.chatContext) ?? turn.app
            let ago = turn.date.map { NookDates.ago($0, now: now) } ?? ""
            return RankedTodayItem(attention: .owed(turn), row: TodayItem(
                id: "owed-\(turn.chat)",
                title: tr("app.today.owed", turn.name),
                subtitle: [context, ago].filter { !$0.isEmpty }.joined(separator: " · "),
                action: tr("app.today.reply"),
                color: NookTheme.amber,
                target: .action { [weak self] in self?.presentChat(turn.chat, asked: true) },
                logo: .source(turn.app)
            ))
        }
    }

    /// The people whose birthday is today, from what you keep about them (`ChatPersonNotes.birthdays(on:)`), with their
    /// newest chat to say congratulations in.
    func birthdayAttention(now: Date = Date()) -> [RankedTodayItem] {
        let keys = ChatFollowUpStore.shared.notes.birthdays(on: now)
        guard !keys.isEmpty else { return [] }
        let people = ChatPeople.people(Array(ChatCaptureService.shared.loadedInbox.threads.values))
        return keys.compactMap { key -> RankedTodayItem? in
            guard let person = people.first(where: { $0.id == key }) else { return nil }
            let chat = person.chats.first
            var target: TodayItem.Target = .none
            if let chat { target = .action { [weak self] in self?.presentChat(chat.chat, asked: true) } }
            return RankedTodayItem(attention: .birthday(person: key, name: person.name, on: now), row: TodayItem(
                id: "birthday-\(key)",
                title: tr("app.today.birthday", person.name),
                subtitle: chat.map { MessagingApps.app(id: $0.app)?.name ?? $0.app } ?? "",
                action: tr("app.today.reply"),
                color: NookTheme.iris,
                target: target,
                logo: .symbol("gift")
            ))
        }
    }

    /// The one thing that waits on you most, for the menu bar: an approval, a question, a reply you owe or a failure.
    func topAttention(now: Date = Date()) -> RankedTodayItem? {
        let candidates = agentAttention(now: now) + owedChatAttention(now: now, limit: 1)
        let scorer = attentionScorer(now: now)
        return scorer.rank(candidates.filter { $0.attention.needsYou != .info }, by: \.attention).first
    }
}
