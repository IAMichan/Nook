import Foundation

/// Starter prompts tailored to what the user is currently doing: the frontmost window, upcoming meeting,
/// waiting agents, open loops, and time of day. Dynamic, avoiding repetitive lists.
extension AppModel {
    var startSuggestions: [String] {
        var ideas: [(priority: Int, text: String)] = []
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let weekday = Calendar.current.component(.weekday, from: now)

        // 1. What's currently in front.
        if let front = screenContext.windows.first(where: { $0.isFront }) {
            for idea in Self.ideas(forApp: front.app, bundleID: front.bundleID, title: front.title) {
                ideas.append((100, idea))
            }
        }

        // 2. An agent waiting on input or stuck.
        if let waiting = hub.sessions.first(where: { $0.status == .waiting || $0.approvalID != nil }) {
            ideas.append((95, tr("suggest.agent.waiting", waiting.name)))
        } else if let failed = hub.sessions.first(where: { $0.status == .failed }) {
            ideas.append((90, tr("suggest.agent.failed", failed.name)))
        }

        // 3. Upcoming calendar event.
        if let next = upcoming.first(where: { $0.end > now }), next.start.timeIntervalSince(now) < 4 * 3600 {
            ideas.append((85, tr("suggest.prepare", Self.short(next.title, 26))))
        }

        // 4. Time of day and day of week.
        let todayCount = upcoming.filter { Calendar.current.isDateInToday($0.start) }.count
        if hour < 11 {
            ideas.append((70, todayCount > 0 ? tr("home.suggestions.summarizeDay") : tr("suggest.day.priority")))
        } else if hour >= 16 {
            let tomorrow = upcoming.filter { Calendar.current.isDateInTomorrow($0.start) }.count
            ideas.append((65, tomorrow > 0 ? tr("suggest.tomorrow") : tr("suggest.finishToday")))
        }
        if weekday == 6, hour >= 14 {
            ideas.append((60, tr("suggest.week.review")))
        }
        if weekday == 2, hour < 12 {
            ideas.append((60, tr("suggest.cal.chart")))
        }

        // 5. Open loops and inbound updates.
        if let loop = loops.first {
            ideas.append((55, loops.count > 1 ? tr("suggest.loops.many", loops.count) : tr("suggest.loops.one", Self.short(loop.title, 28))))
        }
        let active = Set(connectors.active.map(\.id))
        if active.contains("mail") {
            ideas.append((50, tr("home.suggestions.mailToReply")))
        }
        if active.contains("notes") {
            ideas.append((52, tr("home.suggestions.notes")))
        }
        if active.contains("reminders") {
            ideas.append((51, tr("home.suggestions.reminders")))
        }
        for source in connectors.needingAttention.prefix(1) {
            ideas.append((52, tr("suggest.source", source.title)))
        }
        if active.contains("github") {
            ideas.append((45, tr("home.suggestions.github")))
        }
        if active.contains("stripe") {
            ideas.append((40, tr("suggest.stripe")))
        }

        // Fallback: an open-ended prompt that always works.
        ideas.append((10, hour < 12 ? tr("home.suggestions.summarizeDay") : tr("suggest.anything")))

        var seen = Set<String>()
        return ideas.sorted { $0.priority > $1.priority }
            .map { $0.text }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(4)
            .map { $0 }
    }

    /// Relevant suggestions based on the active frontmost application.
    private static func ideas(forApp app: String, bundleID: String, title: String) -> [String] {
        let id = bundleID.lowercased()
        let name = app.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { id.contains($0) || name.contains($0) } }

        if any(["com.apple.mail", "outlook", "spark", "superhuman", "mimestream"]) {
            return [tr("suggest.mail.summarize"), tr("suggest.mail.reply")]
        }
        if any(["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "orion"]) {
            return [tr("suggest.web.summarize"), tr("suggest.web.remember")]
        }
        if any(["xcode", "vscode", "com.microsoft.vscode", "cursor", "zed", "jetbrains", "sublime", "nova", "windsurf"]) {
            return [tr("suggest.code.explain"), tr("suggest.code.bug")]
        }
        if any(["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty"]) {
            return [tr("suggest.terminal.error")]
        }
        if any(["slack", "whatsapp", "telegram", "discord", "teams", "mobilesms", "messages", "signal"]) {
            return [tr("suggest.chat.reply"), tr("suggest.chat.plan")]
        }
        if any(["numbers", "excel", "sheets", "airtable"]) {
            return [tr("suggest.sheet.chart"), tr("suggest.sheet.insight")]
        }
        if any(["pages", "word", "notes", "notion", "obsidian", "bear", "craft", "docs", "textedit"]) {
            return [tr("suggest.doc.improve"), tr("suggest.doc.summary")]
        }
        if any(["ical", "calendar", "fantastical", "busycal", "notion-calendar"]) {
            return [tr("suggest.cal.free"), tr("suggest.cal.chart")]
        }
        if any(["preview", "pdf", "acrobat", "skim"]) {
            return [tr("suggest.pdf.summary")]
        }
        if any(["figma", "sketch", "framer"]) {
            return [tr("suggest.design.feedback")]
        }
        if any(["zoom", "facetime", "meet", "webex"]) {
            return [tr("suggest.call.notes")]
        }
        return title.isEmpty ? [] : [tr("suggest.window.help", short(title, 30))]
    }

    private static func short(_ text: String, _ limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let cut = clean.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
    }
}
