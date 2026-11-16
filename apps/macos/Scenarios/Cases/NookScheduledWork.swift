import AppKit

/// Nook as the user's secretary: work it does on its own shows in the Nook tab. The list has a Scheduled tab beside the
/// conversations with when each task runs next (paused ones under a label of their own), the task's conversation has the bar with run now and pause, a run shows as a marker
/// instead of a question the user typed, and the proposal to schedule one (`schedule_task`) is a plan card to approve.
final class NookScheduledWork: Scenario {
    func testNookScheduledWork() throws {
        try scenario("The Nook tab lists scheduled work, its conversation has the bar, and a run shows as a marker") { nook, screen, app in
            let model = nook.app
            let store = ScheduledTaskStore.shared
            let task = ScheduledTask(title: "Morning update", prompt: "Give me an overview of the messages I received since the previous run, per topic.",
                                     rule: .fixedTime(hour: 9, minute: 0, weekdays: []), target: .nook, createdAt: Date())
            store.save(task, permission: .ask)
            let weekly = ScheduledTask(title: "Weekly mail review", prompt: "Summarize this week's mail.",
                                       rule: .fixedTime(hour: 16, minute: 0, weekdays: [6]), target: .nook, createdAt: Date())
            store.save(weekly, permission: .ask)
            store.setEnabled(weekly.id, false)

            // One run of the morning update in its own conversation, as `ScheduledTaskStore.runInNook` leaves it.
            let conversation = model.chat.startInBackground()
            var question = ChatMessage(role: .user, text: task.prompt)
            question.date = Date().addingTimeInterval(-3600)
            model.chat.append(question, to: conversation)
            model.chat.rename(conversation, to: task.title)
            model.chat.markScheduledRun(conversation, task: task.id)
            var answer = ChatMessage(role: .nook, text: "**3 chats wait for an answer.**\n\n### Work\n- Lisa asks if the deck is ready for Thursday.\n- The team moved stand-up to 9:30.\n\n### Private\n- Mom asks about Sunday dinner.")
            answer.date = Date().addingTimeInterval(-3550)
            model.chat.append(answer, to: conversation)

            // Another conversation where Nook proposes a scheduled task, waiting for the click.
            let ask = model.chat.startInBackground()
            model.chat.append(ChatMessage(role: .user, text: "Give me an update on my messages every morning at 9:00"), to: ask)
            var proposal = ChatMessage(role: .nook, text: "I'll do that for you every morning at 9:00 and let you know when it's ready.")
            proposal.actions = [PlannedAction(tool: "schedule_task", input: [
                "title": "Morning update", "prompt": task.prompt, "schedule": "daily", "time": "09:00"
            ])]
            proposal.actionStates = [.pending]
            proposal.actionIncluded = [true]
            proposal.actionProblems = [[]]
            model.chat.append(proposal, to: ask)

            try nook.openNook(conversation)
            // The conversations tab lists the run's conversation, not the tasks: those have a tab of their own.
            try expect(screen.text("Weekly mail review").first).toBeHidden()
            try screen.button("Scheduled").first.tap()
            try expect(screen.text("Scheduled tasks (2)").first).toBeVisible()
            try expect(screen.text("Morning update").first).toBeVisible()
            try expect(screen.text("Paused and done").first).toBeVisible()
            try expect(screen.text("Weekly mail review").first).toBeVisible()
            try expect(screen.text("Nook does this on its own").first).toBeVisible()
            try expect(screen.labelled("Run now").first).toBeVisible()
            try expect(screen.text("3 chats wait for an answer.").first).toBeVisible()
            try app.screenshot("scheduled-conversation")

            try screen.button("Conversations").first.tap()
            try nook.openNook(ask)
            try expect(screen.text("Morning update").first).toBeVisible()
            try app.screenshot("proposal")
        }
    }
}
