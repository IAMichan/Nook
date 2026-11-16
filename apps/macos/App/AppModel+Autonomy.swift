import Foundation

/// A scheduled task for Nook that carries out steps by itself (`NookAutonomy`): once its run's answer is ready, the steps
/// the task may do unattended (`AutonomyPolicy.unattendedTools`) run at once (`auto`) or after Nook's judge found them
/// routine (`decide`). The rest stays in the conversation for the user's click, as before. The user's yes is the level
/// they chose for the task; every step that runs goes through the plan runner or the mail sender, which write the audit
/// log, and the answer ends with what ran and what still waits.
extension AppModel {
    /// One step of the answer: a plan action (by index) or a mail draft (by id).
    private enum AutonomyTarget {
        case action(Int)
        case mail(UUID)
    }

    func carryOut(reply id: UUID, task: ScheduledTask, level: NookAutonomy, fromOutside: Bool) async {
        guard level != .ask, let message = chat.message(id), !message.planArchived else { return }
        var targets: [AutonomyTarget] = []
        var steps: [AutonomyStep] = []
        let planOpen = message.planState == .pending
        if planOpen {
            let lines = planSteps(message.actions)
            for (index, action) in message.actions.enumerated() {
                guard message.actionIncluded[safe: index] ?? true, (message.actionProblems[safe: index] ?? []).isEmpty,
                      (message.actionStates[safe: index] ?? .pending).canRun else { continue }
                let recipient = ["to", "name", "chat", "repo"].lazy.compactMap { action.input[$0] as? String }.first ?? ""
                let detail = actionFields(action).map { "\($0.label): \($0.value)" }.joined(separator: "\n")
                targets.append(.action(index))
                steps.append(AutonomyStep(tool: action.tool, summary: lines[safe: index]?.text ?? action.tool,
                                          detail: detail, recipient: recipient))
            }
        }
        for mail in message.mails where mail.state == .draft {
            targets.append(.mail(mail.id))
            steps.append(AutonomyStep(tool: AutonomyPolicy.mailTool,
                                      summary: tr("autonomy.step.mail", mail.to, mail.subject),
                                      detail: (mail.cc.isEmpty ? "" : "Cc: \(mail.cc)\n") + mail.body
                                        + (mail.attachments.isEmpty ? "" : "\n[\(mail.attachments.count) attachment(s)]"),
                                      recipient: mail.to))
        }
        guard !steps.isEmpty else { return }

        let split = AutonomyPolicy.split(steps, level: level)
        var chosen = Set(split.run)
        var reasons: [Int: String] = [:]
        // Why a step waits that no level may run by itself (deleting, merging, a command…), or that is past the run's limit.
        let considered = Set(split.run + split.judge)
        for index in steps.indices where !considered.contains(index) {
            reasons[index] = tr(AutonomyPolicy.mayRunUnattended(steps[index].tool) ? "autonomy.reason.limit" : "autonomy.reason.never")
        }
        if !split.judge.isEmpty {
            let prompt = AutonomyPolicy.judgePrompt(title: task.title, prompt: task.prompt,
                                                    steps: split.judge.map { ($0 + 1, steps[$0]) }, fromOutside: fromOutside)
            // No answer from the judge (no brain, a timeout): every step waits, as it would without the setting.
            let answer = await brain.rewrite(system: AutonomyPolicy.judgeSystem, prompt: prompt, timeout: 90) ?? ""
            let verdicts = AutonomyPolicy.verdicts(answer)
            for index in split.judge {
                guard let verdict = verdicts[index + 1] else { continue }
                if verdict.run { chosen.insert(index) } else if !verdict.reason.isEmpty { reasons[index] = verdict.reason }
            }
        }
        guard !chosen.isEmpty else {
            note(reply: id, ran: 0, failed: 0, waiting: steps.indices.map { (steps[$0].summary, reasons[$0]) }, level: level)
            return
        }

        let approval = "scheduled_autonomy: \(task.title) (\(level.rawValue))"
        var ran = 0, failed = 0

        // Plan actions: only the chosen ones run; the others go back to waiting for the user's Run afterwards.
        let chosenActions = Set(chosen.compactMap { index -> Int? in
            if case .action(let action) = targets[index] { return action }
            return nil
        })
        if !chosenActions.isEmpty {
            let before = message.actionIncluded
            chat.update(id) { message in
                message.actionIncluded = message.actions.indices.map { chosenActions.contains($0) }
            }
            await runPlan(id, approval: approval)?.value
            if let after = chat.message(id) {
                for index in chosenActions {
                    switch after.actionStates[safe: index] {
                    case .done?, .verified?: ran += 1
                    case .failed?: failed += 1
                    default: break
                    }
                }
                // What was left for the user is theirs to run: switched on as it was, and the plan open again.
                let remains = after.actions.indices.contains { !chosenActions.contains($0) && (before[safe: $0] ?? true) }
                chat.update(id) { message in
                    message.actionIncluded = message.actions.indices.map { index in
                        chosenActions.contains(index) || (before[safe: index] ?? true)
                    }
                    if remains, case .done = message.planState { message.planState = .pending }
                }
            }
        }

        // Mail drafts: sent one by one, each recorded.
        for index in chosen.sorted() {
            guard case .mail(let mailID) = targets[index],
                  let draft = chat.message(id)?.mails.first(where: { $0.id == mailID }), draft.state == .draft else { continue }
            if await deliverMail(draft, approval: approval) { ran += 1 } else { failed += 1 }
        }

        let waiting = steps.indices.filter { !chosen.contains($0) }.map { (steps[$0].summary, reasons[$0]) }
        note(reply: id, ran: ran, failed: failed, waiting: waiting, level: level)
    }

    /// Ends the answer with what the task did by itself and what still waits, so the user sees it at a glance.
    private func note(reply id: UUID, ran: Int, failed: Int, waiting: [(String, String?)], level: NookAutonomy) {
        var paragraphs: [String] = []
        if ran > 0 { paragraphs.append(ran == 1 ? tr("autonomy.note.ran.one") : tr("autonomy.note.ran", ran)) }
        if failed > 0 { paragraphs.append(tr("autonomy.note.failed", failed)) }
        if !waiting.isEmpty {
            let items = waiting.prefix(8).map { summary, reason in "- " + summary + (reason.map { " — \($0)" } ?? "") }
            paragraphs.append(tr("autonomy.note.waiting", waiting.count) + "\n" + items.joined(separator: "\n"))
        }
        guard !paragraphs.isEmpty else { return }
        let block = "\n\n---\n\n_" + tr("autonomy.note.title", level.label) + "_\n\n" + paragraphs.joined(separator: "\n\n")
        chat.update(id) { $0.text += block }
    }
}
