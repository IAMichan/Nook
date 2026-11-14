import Foundation

/// One starter on the home screen: the question it asks, and the icon of what it is about.
struct StartSuggestion: Identifiable, Hashable {
    var text: String
    var logo: TodayItem.Logo
    var id: String { text }
}

/// Starter prompts built from what is actually going on: the frontmost window, a review or failing build on GitHub,
/// overdue tasks, unread mail, a waiting agent and the time of day. Each names something real when it can ("Review
/// “Fix login” for me") instead of asking the user what is in a source, one per topic, and none repeats a line that
/// Today already shows above them.
extension AppModel {
    var startSuggestions: [StartSuggestion] {
        var ideas: [(priority: Int, topic: String, suggestion: StartSuggestion)] = []
        func add(_ priority: Int, _ topic: String, _ text: String, _ logo: TodayItem.Logo) {
            ideas.append((priority, topic, StartSuggestion(text: text, logo: logo)))
        }
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let weekday = calendar.component(.weekday, from: now)
        let active = Set(connectors.active.map(\.id))

        // 1. What's in front: the most direct help there is.
        if let front = screenContext.windows.first(where: { $0.isFront }),
           let idea = Self.ideas(forApp: front.app, bundleID: front.bundleID, title: front.title).first {
            add(100, "front", idea.text, .symbol(idea.symbol))
        }

        // 2. An agent waiting on input or stuck: Today has the row to open it, this asks what it needs.
        if let waiting = hub.sessions.first(where: { $0.status == .waiting || $0.approvalID != nil }) {
            add(95, "agent", tr("suggest.agent.waiting", waiting.name), .agent(waiting.name))
        } else if let failed = hub.sessions.first(where: { $0.status == .failed }) {
            add(90, "agent", tr("suggest.agent.failed", failed.name), .agent(failed.name))
        }

        // 3. GitHub: the pull request itself, not "what about GitHub?".
        if active.contains("github"), let github = connectors.source(id: "github") {
            let items = github.status.items
            if let review = items.first(where: { $0.id.hasPrefix("review-") }) {
                add(88, "github", tr("suggest.github.review", Self.short(review.title, 34)), .source("github"))
            } else if let broken = items.first(where: { $0.id.hasPrefix("pr-") && $0.tone == .bad }) {
                add(86, "github", tr("suggest.github.failing", Self.short(broken.title, 30)), .source("github"))
            }
        }

        // 4. The next meeting in the coming hours, unless Today already shows it with its own "Prepare".
        let today = upcoming.filter { calendar.isDateInToday($0.start) }
        let shown = upcoming.first(where: { $0.end > now }).flatMap { $0.start.timeIntervalSince(now) < 3 * 3600 ? $0.id : nil }
        if let next = upcoming.first(where: { $0.start > now && $0.id != shown }), next.start.timeIntervalSince(now) < 6 * 3600 {
            add(80, "calendar", tr("suggest.prepare", Self.short(next.title, 26)), .source("calendar"))
        }

        // 5. Tasks: overdue ones first, otherwise fit the open ones into the day.
        if active.contains("reminders"), let reminders = connectors.source(id: "reminders") {
            if reminders.status.items.contains(where: { $0.tone == .attention }) {
                add(78, "tasks", tr("suggest.reminders.overdue"), .source("reminders"))
            } else if !reminders.status.items.isEmpty, hour < 17 {
                add(56, "tasks", tr("suggest.reminders.plan"), .source("reminders"))
            }
        }

        // 6. Mail: the newest unread message by name, or what still needs an answer.
        if active.contains("mail"), let mail = connectors.source(id: "mail") {
            if let unread = mail.status.items.first, !unread.subtitle.isEmpty {
                add(60, "mail", tr("suggest.mail.from", Self.short(unread.subtitle, 22)), .source("mail"))
            } else {
                add(50, "mail", tr("home.suggestions.mailToReply"), .source("mail"))
            }
        }

        // 7. The time of day and the day of the week.
        if hour < 11 {
            add(70, "day", today.isEmpty ? tr("suggest.day.priority") : tr("suggest.day.plan"), .symbol("sun.horizon"))
        } else if hour < 16 {
            if active.contains("calendar") || !today.isEmpty {
                add(54, "day", tr("suggest.cal.today"), .source("calendar"))
            } else {
                add(54, "day", tr("suggest.day.priority"), .symbol("target"))
            }
        } else {
            let tomorrow = upcoming.contains { calendar.isDateInTomorrow($0.start) }
            add(65, "day", tomorrow ? tr("suggest.tomorrow") : tr("suggest.finishToday"), .symbol(tomorrow ? "calendar" : "checkmark.circle"))
        }
        if weekday == 6, hour >= 14 {
            add(62, "week", tr("suggest.week.review"), .symbol("chart.bar.xaxis"))
        }
        if weekday == 2, hour < 12 {
            add(62, "week", tr("suggest.cal.chart"), .symbol("chart.bar.xaxis"))
        }

        // 8. Open loops beyond the three Today lists.
        if loops.count > 3 {
            add(52, "loops", tr("suggest.loops.many", loops.count), .symbol("checklist"))
        }
        if active.contains("stripe") {
            add(40, "stripe", tr("suggest.stripe"), .source("stripe"))
        }

        // Fallback: open-ended prompts that always work.
        add(10, "fallback", tr("home.suggestions.summarizeDay"), .symbol("text.alignleft"))
        add(9, "anything", tr("suggest.anything"), .symbol("sparkles"))

        var topics = Set<String>()
        var texts = Set<String>()
        return ideas.sorted { $0.priority > $1.priority }
            .filter { topics.insert($0.topic).inserted && texts.insert($0.suggestion.text.lowercased()).inserted }
            .prefix(4)
            .map { $0.suggestion }
    }

    /// Relevant suggestions based on the active frontmost application.
    private static func ideas(forApp app: String, bundleID: String, title: String) -> [(text: String, symbol: String)] {
        // The kind of app is `AppCatalog`'s, the same list quiet mode and double tap use.
        switch AppCatalog.kind(app: app, bundleID: bundleID) {
        case .mail:
            return [(tr("suggest.mail.reply"), "arrowshape.turn.up.left"), (tr("suggest.mail.summarize"), "envelope")]
        case .browser:
            return [(tr("suggest.web.summarize"), "safari"), (tr("suggest.web.remember"), "bookmark")]
        case .editor:
            return [(tr("suggest.code.bug"), "ladybug"), (tr("suggest.code.explain"), "chevron.left.forwardslash.chevron.right")]
        case .terminal:
            return [(tr("suggest.terminal.error"), "terminal")]
        case .chat:
            return [(tr("suggest.chat.reply"), "bubble.left.and.bubble.right"), (tr("suggest.chat.plan"), "calendar.badge.plus")]
        case .spreadsheet:
            return [(tr("suggest.sheet.insight"), "tablecells"), (tr("suggest.sheet.chart"), "chart.bar.xaxis")]
        case .document:
            return [(tr("suggest.doc.improve"), "wand.and.stars"), (tr("suggest.doc.summary"), "text.alignleft")]
        case .calendar:
            return [(tr("suggest.cal.free"), "calendar"), (tr("suggest.cal.chart"), "chart.bar.xaxis")]
        case .pdf:
            return [(tr("suggest.pdf.summary"), "doc.text")]
        case .design:
            return [(tr("suggest.design.feedback"), "paintpalette")]
        case .call:
            return [(tr("suggest.call.notes"), "waveform")]
        case nil:
            return title.isEmpty ? [] : [(tr("suggest.window.help", short(title, 30)), "macwindow")]
        }
    }

    private static func short(_ text: String, _ limit: Int) -> String {
        // `limit` characters of text, the ellipsis after them.
        TextKit.clip(text.trimmingCharacters(in: .whitespacesAndNewlines), to: limit + 1, wordBoundary: true)
    }
}
