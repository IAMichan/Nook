import Foundation

/// The model's own reading of a question, before Nook looks anything up. Keyword lists and regular expressions guess
/// badly at what a question means: "heb ik chats openstaan in WhatsApp?" is not a search for the words "chats" and
/// "whatsapp" in files and code, it asks for the unread WhatsApp chats. So the brain first answers three short
/// questions about the question itself (what does the user want, where does that live, what to search for), and Nook
/// does its research with that plan. When the brain cannot plan in time, Nook falls back to its own keyword research.
///
/// This file holds the plain parts (the prompt, parsing the answer, turning a plan into lookups), so they are tested in
/// isolation; `BrainService.plan` runs it on the selected brain.
struct QueryPlan: Equatable {
    enum Kind: String {
        /// Find something specific in the user's data ("wat zei Lisa over de offerte?").
        case lookup
        /// The newest, unread, open or unanswered items of a source ("heb ik chats openstaan?", "nieuwe mail?").
        case listing
        /// Do something (make an event, send a mail): the regular action flow handles it.
        case action
        /// General knowledge or the web; the user's own data does not hold the answer.
        case general
        /// A greeting or thanks.
        case chat
    }

    /// One sentence: what the user really wants to know or have done.
    var goal: String
    var kind: Kind
    /// Source ids where the answer lives, most likely first.
    var sources: [String]
    /// Short keyword searches (one to three words each), best first. Empty for a listing.
    var queries: [String]
    /// The days the question is about, start of the first to the end of the last, when it asks about a day or period
    /// ("heb ik morgen een gesprek met Aron?"). The calendar is checked for exactly these days.
    var from: Date? = nil
    var to: Date? = nil

    /// Words to search with, as Nook's research uses them.
    var terms: Research.Terms {
        var terms = Research.Terms()
        for query in queries {
            let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lower.isEmpty else { continue }
            if lower.contains(" ") { terms.phrases.append(lower) }
            for word in Research.words(of: lower) where !terms.words.contains(word) && word.count >= 2 { terms.words.append(word) }
        }
        // The phrases are whole searches; the words are what a hit must contain.
        terms.phrases = Array(terms.phrases.prefix(3))
        terms.words = Array(terms.words.prefix(8))
        terms.names = queries.flatMap { $0.split(separator: " ").map(String.init) }.filter { $0.first?.isUppercase ?? false }
        return terms
    }
}

enum QueryPlanner {
    /// What the planner knows about one source: its id, its name and what Nook can do with it.
    struct Source: Equatable {
        var id: String
        var title: String
        var canSearch: Bool
        var canList: Bool
    }

    static let system = """
    You plan how to answer a question asked to Nook, the assistant on the user's Mac. You do not answer it.
    Work out what the user really wants and where on their Mac or in their services that lives, then reply with ONLY one JSON object:
    {"goal": "...", "kind": "lookup|listing|action|general|chat", "sources": ["id", ...], "queries": ["...", ...], "from": "YYYY-MM-DD", "to": "YYYY-MM-DD"}
    - goal: one short sentence in English: what exactly the user wants to know or have done.
    - kind: lookup = find something specific in their data; listing = the newest, unread, open or unanswered items of a source \
    (no keywords needed); action = create, send, change or open something; general = general knowledge, news or the web; chat = greeting or thanks.
    - sources: ids from the list below where the answer most likely is, best first, at most 4. A source the user names comes first. \
    Do not add sources that merely could mention the topic: a question about chats is answered by the chat apps, not by files or code. \
    A question about the user's schedule (an appointment, meeting, call or talk with someone, being busy or free, what is planned on \
    a day) is answered by calendar first; add a chat or mail source only when it may have been arranged there and not put on the calendar. \
    A question about what is visible right now ("this", "here", "what I'm looking at") is answered by screen.
    - queries: 1 to 3 short keyword searches (1 to 3 words, the words that would literally appear in the item: names, subjects, \
    synonyms; in the language the data is likely in). Never the name of a source, never words like open/unread/latest. Empty for a listing.
    - from, to: only when the question is about a day or period (today, tomorrow, friday, next week): its first and last day, \
    worked out from today's date. Leave both out otherwise.
    """

    static func prompt(question: String, history: [ChatTurn], sources: [Source], now: Date = Date()) -> String {
        var lines: [String] = []
        let recent = history.suffix(4)
        if !recent.isEmpty {
            lines.append("Conversation so far:")
            for turn in recent { lines.append((turn.fromUser ? "User: " : "Nook: ") + String(turn.text.prefix(300)).replacingOccurrences(of: "\n", with: " ")) }
            lines.append("")
        }
        lines.append("Sources (id — name: what Nook can do):")
        for source in sources {
            var abilities: [String] = []
            if source.canSearch { abilities.append("search") }
            if agendas.contains(source.id) { abilities = ["events and free time on the days asked"] } else if source.canList { abilities.append("newest/unread/open items") }
            lines.append("- \(source.id) — \(source.title): " + (abilities.isEmpty ? "context" : abilities.joined(separator: ", ")))
        }
        lines.append("")
        lines.append("Today: \(NookDates.long(now)).")
        lines.append("Question: \(question)")
        lines.append("JSON:")
        return lines.joined(separator: "\n")
    }

    /// The plan in the model's reply: the first JSON object in it, with unknown sources dropped. Nil when there is none.
    static func parse(_ reply: String, known: Set<String>) -> QueryPlan? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let kind = (object["kind"] as? String).flatMap { QueryPlan.Kind(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) } ?? .lookup
        var sources: [String] = []
        for raw in (object["sources"] as? [Any]) ?? [] {
            guard let id = (raw as? String)?.lowercased().trimmingCharacters(in: .whitespaces) else { continue }
            // Models sometimes answer with the name instead of the id.
            let match = known.contains(id) ? id : known.first { SourceCatalog.title($0).lowercased() == id }
            if let match, !sources.contains(match) { sources.append(match) }
        }
        let queries = ((object["queries"] as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 60 }
        let days = window(from: object["from"] as? String, to: object["to"] as? String)
        return QueryPlan(goal: String(((object["goal"] as? String) ?? "").prefix(240)), kind: kind,
                         sources: Array(sources.prefix(4)), queries: Array(queries.prefix(3)), from: days?.from, to: days?.to)
    }

    /// The planned days as a time range: a date-only `to` includes that whole day, a missing one means only `from`'s
    /// day. At most 14 days, as check_availability allows.
    static func window(from: String?, to: String?, calendar: Calendar = .current) -> (from: Date, to: Date)? {
        guard let fromText = from?.trimmingCharacters(in: .whitespaces), let start = NookDates.parse(fromText) else { return nil }
        let first = fromText.count == 10 ? calendar.startOfDay(for: start) : start
        var end = to.flatMap { text -> Date? in
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard let date = NookDates.parse(trimmed) else { return nil }
            return trimmed.count == 10 ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) : date
        } ?? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: first)) ?? first
        if end <= first { end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: first)) ?? first }
        return (first, min(end, first.addingTimeInterval(14 * 86_400)))
    }

    /// Sources that are calendars: checked together, for the planned days, with check_availability.
    static let agendas: Set<String> = ["calendar", "icalfeeds", "calcom"]

    /// The lookups for a plan: every query in every planned source that can search, and the source's own overview for a
    /// listing (or for a source that cannot search). Searches with several queries run each one, so a synonym the model
    /// thought of is tried too.
    static func lookups(_ plan: QueryPlan, question: String, available: [Prefetch.Available], limit: Int = 8, now: Date = Date()) -> [Prefetch.Call] {
        var searches: [Prefetch.Call] = []
        var overviews: [Prefetch.Call] = []
        // The calendar the planner picked is read for the days the question is about (the coming week without a day),
        // across every calendar at once, and before anything else.
        var agenda: [Prefetch.Call] = []
        if plan.sources.contains(where: { agendas.contains($0) }), available.contains(where: { $0.name == "check_availability" }) {
            let start = plan.from ?? Calendar.current.startOfDay(for: now)
            let end = plan.to ?? start.addingTimeInterval(7 * 86_400)
            agenda.append(Prefetch.Call(tool: "check_availability", input: ["from": NookDates.iso(start), "to": NookDates.iso(end)]))
        }
        for source in plan.sources where !Prefetch.inContext.contains(source) && !agendas.contains(source) {
            var searched = false
            if plan.kind != .listing || !plan.queries.isEmpty {
                for query in plan.queries.prefix(2) {
                    let terms = Research.Terms(words: Research.words(of: query.lowercased()), names: query.split(separator: " ").map(String.init).filter { $0.first?.isUppercase ?? false })
                    if let call = Research.search(source: source, terms: terms, question: question, available: available),
                       !searches.contains(where: { $0.tool == call.tool && NSDictionary(dictionary: $0.input).isEqual(to: call.input) }) {
                        searches.append(call)
                        searched = true
                    }
                }
            }
            if plan.kind == .listing || !searched {
                overviews += Prefetch.calls(for: question, relevant: [source], available: available, limit: 1)
            }
        }
        // A listing is answered by the overviews; a lookup by the searches.
        let ordered = agenda + (plan.kind == .listing ? overviews + searches : searches + overviews)
        return Array(ordered.prefix(limit))
    }
}
