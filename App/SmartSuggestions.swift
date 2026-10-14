import Foundation

/// Vragen om mee te beginnen die passen bij wat je nu doet: het venster dat voor staat, je volgende afspraak,
/// agents die wachten, open punten en het moment van de dag. Geen vaste lijst, dus nooit steeds hetzelfde.
extension AppModel {
    var startSuggestions: [String] {
        var ideas: [(priority: Int, text: String)] = []
        let now = Date()
        let hour = Calendar.current.component(.hour, from: now)
        let weekday = Calendar.current.component(.weekday, from: now)

        // 1. Wat je nu voor je hebt.
        if let front = screenContext.windows.first(where: { $0.isFront }) {
            for idea in Self.ideas(forApp: front.app, bundleID: front.bundleID, title: front.title) {
                ideas.append((100, idea))
            }
        }

        // 2. Een agent die op je wacht of vastliep.
        if let waiting = hub.sessions.first(where: { $0.status == .waiting || $0.approvalID != nil }) {
            ideas.append((95, "Wat heeft \(waiting.name) van me nodig?"))
        } else if let failed = hub.sessions.first(where: { $0.status == .failed }) {
            ideas.append((90, "Waarom liep \(failed.name) vast?"))
        }

        // 3. Je volgende afspraak.
        if let next = upcoming.first(where: { $0.end > now }), next.start.timeIntervalSince(now) < 4 * 3600 {
            ideas.append((85, "Bereid me voor op \(Self.short(next.title, 26))"))
        }

        // 4. Moment van de dag en de week.
        let todayCount = upcoming.filter { Calendar.current.isDateInToday($0.start) }.count
        if hour < 11 {
            ideas.append((70, todayCount > 0 ? "Vat mijn dag samen" : "Wat is vandaag het belangrijkst?"))
        } else if hour >= 16 {
            let tomorrow = upcoming.filter { Calendar.current.isDateInTomorrow($0.start) }.count
            ideas.append((65, tomorrow > 0 ? "Wat staat er morgen op de planning?" : "Wat moet ik nog afronden vandaag?"))
        }
        if weekday == 6, hour >= 14 {
            ideas.append((60, "Hoe ging mijn week?"))
        }
        if weekday == 2, hour < 12 {
            ideas.append((60, "Hoe druk wordt mijn week? Maak er een grafiek van"))
        }

        // 5. Wat er nog openstaat en wat er binnenkomt.
        if let loop = loops.first {
            ideas.append((55, loops.count > 1 ? "Help me mijn \(loops.count) open punten afronden" : "Help me met \(Self.short(loop.title, 28))"))
        }
        let active = Set(connectors.active.map(\.id))
        if active.contains("mail") {
            ideas.append((50, "Welke mail moet ik beantwoorden?"))
        }
        for source in connectors.needingAttention.prefix(1) {
            ideas.append((52, "Wat moet ik doen met \(source.title)?"))
        }
        if active.contains("github") {
            ideas.append((45, "Wat wacht er op mij op GitHub?"))
        }
        if active.contains("stripe") {
            ideas.append((40, "Hoe gaat de omzet deze maand? Met grafiek"))
        }

        // Altijd iets: een ruime vraag die nooit verkeerd is.
        ideas.append((10, hour < 12 ? "Vat mijn dag samen" : "Waar kun je me nu mee helpen?"))

        var seen = Set<String>()
        return ideas.sorted { $0.priority > $1.priority }
            .map { $0.text }
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(4)
            .map { $0 }
    }

    /// Wat logisch is in de app die voor staat.
    private static func ideas(forApp app: String, bundleID: String, title: String) -> [String] {
        let id = bundleID.lowercased()
        let name = app.lowercased()
        func any(_ needles: [String]) -> Bool { needles.contains { id.contains($0) || name.contains($0) } }

        if any(["com.apple.mail", "outlook", "spark", "superhuman", "mimestream"]) {
            return ["Vat deze mail samen", "Schrijf een antwoord op deze mail"]
        }
        if any(["safari", "chrome", "firefox", "arc", "brave", "edge", "opera", "vivaldi", "orion"]) {
            return ["Vat deze pagina samen", "Wat moet ik hiervan onthouden?"]
        }
        if any(["xcode", "vscode", "com.microsoft.vscode", "cursor", "zed", "jetbrains", "sublime", "nova", "windsurf"]) {
            return ["Leg uit wat deze code doet", "Zie je hier een fout?"]
        }
        if any(["terminal", "iterm", "warp", "ghostty", "kitty", "alacritty"]) {
            return ["Wat betekent deze foutmelding?"]
        }
        if any(["slack", "whatsapp", "telegram", "discord", "teams", "mobilesms", "messages", "signal"]) {
            return ["Help me antwoorden op dit gesprek", "Staat hier iets in om te plannen?"]
        }
        if any(["numbers", "excel", "sheets", "airtable"]) {
            return ["Maak een grafiek van deze cijfers", "Wat valt op in deze cijfers?"]
        }
        if any(["pages", "word", "notes", "notion", "obsidian", "bear", "craft", "docs", "textedit"]) {
            return ["Maak deze tekst beter", "Vat dit samen in drie punten"]
        }
        if any(["ical", "calendar", "fantastical", "busycal", "notion-calendar"]) {
            return ["Waar heb ik deze week nog tijd?", "Hoe druk is mijn week? Maak er een grafiek van"]
        }
        if any(["preview", "pdf", "acrobat", "skim"]) {
            return ["Vat dit document samen"]
        }
        if any(["figma", "sketch", "framer"]) {
            return ["Wat kan beter aan dit ontwerp?"]
        }
        if any(["zoom", "facetime", "meet", "webex"]) {
            return ["Maak notities van dit gesprek"]
        }
        return title.isEmpty ? [] : ["Help me met \(short(title, 30))"]
    }

    private static func short(_ text: String, _ limit: Int) -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > limit else { return clean }
        let cut = clean.prefix(limit)
        return String(cut[..<(cut.lastIndex(of: " ") ?? cut.endIndex)]) + "…"
    }
}
