import Foundation

// Which sources Nook uses for a query. Three concerns converge here:
// - the catalog: what sources exist, what kind of connection it is, and which tools belong to it;
// - the scope (SourceScope): what the user allows, via the source picker in the chat or within the query itself
//   ("only my calendar and mail", "without my screen");
// - the routing (SourceRouter): which allowed sources are worth sending in full for this query.
// Everything here is standard Foundation code without UI, so it can be tested in isolation.

/// What kind of connection a source uses, showing the user how it is connected and what that entails.
enum SourceKind: String, Codable, CaseIterable {
    /// On your Mac: Calendar, Reminders, Mail, browser, files, clipboard, screen.
    case builtIn
    /// Signing in to the service itself (GitHub).
    case oauth
    /// An API key pasted manually (Stripe, Vercel, Notion…).
    case apiKey
    /// A custom source with a web API or webhook.
    case custom
    /// The open web.
    case web
    /// Nook's own data (open loops).
    case nook
}

struct SourceDescriptor: Equatable {
    let id: String
    let title: String
    let kind: SourceKind
}

enum SourceCatalog {
    /// Pseudo-sources that are not external integrations but can be toggled on or off per query.
    static let screen = "screen"
    static let web = "web"
    static let loops = "loops"
    /// What Nook learned about the user (`MemoryBook`).
    static let memory = "memory"

    /// Sources Nook knows out of the box. Connectors added later (MCP servers, new services) register themselves with
    /// `register(_:tools:aliases:intents:)`, so adding one does not mean editing the tables in this file.
    static let builtIn: [SourceDescriptor] = [
        SourceDescriptor(id: "calendar", title: "Agenda", kind: .builtIn),
        SourceDescriptor(id: "icalfeeds", title: "Andere agenda's", kind: .apiKey),
        SourceDescriptor(id: "calcom", title: "Cal.com", kind: .apiKey),
        SourceDescriptor(id: "reminders", title: "Herinneringen", kind: .builtIn),
        SourceDescriptor(id: "notes", title: "Notities", kind: .builtIn),
        SourceDescriptor(id: "messages", title: "Berichten", kind: .builtIn),
        SourceDescriptor(id: "whatsapp", title: "WhatsApp", kind: .builtIn),
        SourceDescriptor(id: "bear", title: "Bear", kind: .builtIn),
        SourceDescriptor(id: "callnotes", title: "Gesprekken", kind: .nook),
        SourceDescriptor(id: "system", title: "Deze Mac", kind: .builtIn),
        SourceDescriptor(id: "things", title: "Things", kind: .builtIn),
        SourceDescriptor(id: loops, title: "Open punten", kind: .nook),
        SourceDescriptor(id: memory, title: "Geheugen", kind: .nook),
        SourceDescriptor(id: "mail", title: "Mail", kind: .builtIn),
        SourceDescriptor(id: "browser", title: "Browser", kind: .builtIn),
        SourceDescriptor(id: "terminal", title: "Terminal", kind: .builtIn),
        SourceDescriptor(id: "files", title: "Bestanden", kind: .builtIn),
        SourceDescriptor(id: "contacts", title: "Contacten", kind: .builtIn),
        SourceDescriptor(id: "clipboard", title: "Klembord", kind: .builtIn),
        SourceDescriptor(id: screen, title: "Scherm", kind: .builtIn),
        SourceDescriptor(id: "github", title: "GitHub", kind: .oauth),
        SourceDescriptor(id: "vercel", title: "Vercel", kind: .apiKey),
        SourceDescriptor(id: "stripe", title: "Stripe", kind: .apiKey),
        SourceDescriptor(id: "notion", title: "Notion", kind: .apiKey),
        SourceDescriptor(id: "n8n", title: "n8n", kind: .apiKey),
        SourceDescriptor(id: "resend", title: "Resend", kind: .apiKey),
        SourceDescriptor(id: "customsources", title: "Eigen bronnen", kind: .custom),
        SourceDescriptor(id: web, title: "Web", kind: .web)
    ]

    static var all: [SourceDescriptor] {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return builtIn + registry.descriptors.filter { added in !builtIn.contains { $0.id == added.id } }
    }

    /// What connectors registered at runtime: their descriptor, which tools are theirs, and how people refer to them.
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var descriptors: [SourceDescriptor] = []
        var tools: [String: String] = [:]
        var aliases: [(pattern: String, ids: [String])] = []
        var intents: [(pattern: String, ids: [String])] = []
    }
    private static let registry = Registry()

    /// Makes a source known to the catalog: its tools then follow the source picker and per-chat restrictions, and the
    /// router can pick it for a question. `aliases` and `intents` are regular expressions (case-insensitive).
    static func register(_ descriptor: SourceDescriptor, tools: [String], aliases: [String] = [], intents: [String] = []) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.descriptors.removeAll { $0.id == descriptor.id }
        registry.descriptors.append(descriptor)
        registry.tools = registry.tools.filter { $0.value != descriptor.id }
        for tool in tools { registry.tools[tool] = descriptor.id }
        registry.aliases.removeAll { $0.ids == [descriptor.id] }
        registry.intents.removeAll { $0.ids == [descriptor.id] }
        let escapedTitle = NSRegularExpression.escapedPattern(for: descriptor.title.lowercased())
        let allAliases = (aliases + [escapedTitle]).filter { !$0.isEmpty }
        registry.aliases.append((allAliases.joined(separator: "|"), [descriptor.id]))
        if !intents.isEmpty { registry.intents.append((intents.joined(separator: "|"), [descriptor.id])) }
    }

    /// Removes a runtime source (an MCP server that was deleted).
    static func unregister(_ id: String) {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        registry.descriptors.removeAll { $0.id == id }
        registry.tools = registry.tools.filter { $0.value != id }
        registry.aliases.removeAll { $0.ids == [id] }
        registry.intents.removeAll { $0.ids == [id] }
    }

    static var registeredIntents: [(pattern: String, ids: [String])] {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return registry.intents
    }

    /// Sources that hold personal data on this Mac: the preset for "only on this Mac" (Settings › Brain).
    static let personal: Set<String> = [
        "calendar", "icalfeeds", "reminders", "notes", "messages", "whatsapp", "bear", "things", loops, "mail", "callnotes",
        "browser", "files", "contacts", "clipboard", screen, memory
    ]

    static func descriptor(_ id: String) -> SourceDescriptor? {
        all.first { $0.id == id }
    }

    static func title(_ id: String) -> String {
        descriptor(id)?.title ?? id
    }

    /// Tools associated with a source. Tools without a source (charts, open app, music…) are always allowed.
    private static let exactTools: [String: String] = [
        "list_events": "calendar", "create_event": "calendar", "update_event": "calendar", "delete_event": "calendar",
        "check_availability": "calendar",
        "create_reminder": "reminders", "complete_reminder": "reminders", "delete_reminder": "reminders", "list_reminders": "reminders", "search_reminders": "reminders",
        "list_notes": "notes", "search_notes": "notes", "read_note": "notes", "create_note": "notes",
        "search_messages": "messages", "read_messages": "messages", "messages_open_chats": "messages",
        "search_whatsapp": "whatsapp", "read_whatsapp": "whatsapp", "whatsapp_open_chats": "whatsapp", "whatsapp_live": "whatsapp", "whatsapp_send": "whatsapp",
        "search_call_notes": "callnotes", "read_call_note": "callnotes", "mac_status": "system",
        "search_bear": "bear", "read_bear": "bear", "search_things": "things",
        "search_mail": "mail", "read_mail": "mail", "mail_unread": "mail", "inbox_mail": "mail",
        "search_files": "files", "read_file": "files",
        "read_browser_tab": "browser", "read_nook_browser": "browser", "open_in_nook_browser": "browser", "read_open_app": "browser",
        "run_command": "terminal",
        "read_screen": screen, "read_app": screen,
        "list_running_apps": screen, "get_active_app": screen,
        "search_contacts": "contacts", "read_clipboard": "clipboard",
        "list_open_loops": loops, "add_open_loop": loops, "complete_open_loop": loops,
        "remember": memory, "forget": memory, "recall_memory": memory,
        "search_web": web, "read_webpage": web, "web_search": web, "get_weather": web,
        "read_source": "customsources", "send_to_source": "customsources",
        "vercel_deployments": "vercel", "stripe_payments": "stripe", "notion_search": "notion", "notion_read_page": "notion",
        "calcom_bookings": "calcom", "n8n_status": "n8n", "resend_overview": "resend"
    ]

    static func source(forTool name: String) -> String? {
        if let exact = exactTools[name] { return exact }
        registry.lock.lock()
        let registered = registry.tools[name]
        registry.lock.unlock()
        if let registered { return registered }
        if name.hasPrefix("github_") { return "github" }
        return nil
    }

    /// How the user refers to a source (Dutch, English, German). A single word can cover multiple sources:
    /// "agenda" covers Apple Calendar, your ICS calendars, and Cal.com combined.
    static var aliases: [(pattern: String, ids: [String])] {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        return builtInAliases + registry.aliases
    }

    private static let builtInAliases: [(pattern: String, ids: [String])] = [
        (#"agenda'?s?|kalender\w*|calendars?|ical"#, ["calendar", "icalfeeds", "calcom"]),
        (#"cal\.com"#, ["calcom"]),
        (#"herinnering\w*|reminders?|erinnerung\w*"#, ["reminders"]),
        (#"taken|takenlijst|tasks?|to-?do'?s?|aufgaben"#, ["reminders", loops]),
        (#"notitie\w*|notes?|memo'?s?|aantekening\w*"#, ["notes", "bear"]),
        (#"imessages?|sms'?(je|jes|en)?|berichten-?app|messages app|appje\w*|ge-?appt|appte\w*"#, ["messages", "whatsapp"]),
        (#"whats-?app\w*"#, ["whatsapp"]),
        (#"bear"#, ["bear"]),
        (#"(opgenomen|mijn) (gesprekk?en|calls|meetings)|gespreksnotities|notulen|transcript\w*|recorded calls?|call notes|meeting notes"#, ["callnotes"]),
        (#"things( ?3| app|-app)"#, ["things"]),
        (#"contact\w*|telefoon\w*|adresboek|address book"#, ["contacts"]),
        (#"open punten|open loops?"#, [loops]),
        (#"e-?mails?|mail|mailbox|inbox|postvak\w*|posteingang"#, ["mail"]),
        (#"browser\w*|tabs?|tabblad\w*|safari|chrome"#, ["browser"]),
        (#"terminal\w*|shell|commando'?s?|command line|kommandozeile"#, ["terminal"]),
        (#"bestand\w*|files?|documenten|documents?|dokumente?n?|dateien|pdf'?s?|spotlight"#, ["files"]),
        (#"klembord|clipboard|zwischenablage"#, ["clipboard"]),
        (#"scherm\w*|screen\w*|bildschirm\w*|vensters?"#, [screen]),
        (#"internet|web|online|google"#, [web]),
        (#"github|pull requests?|pr'?s|issues?"#, ["github"]),
        (#"vercel|deploy\w*"#, ["vercel"]),
        (#"stripe|betaling\w*|payments?"#, ["stripe"]),
        (#"notion"#, ["notion"]),
        (#"n8n|workflows?"#, ["n8n"]),
        (#"resend"#, ["resend"]),
        (#"slack|teams|discord|telegram|eigen bronn?e?n?|custom sources?"#, ["customsources"])
    ]

    /// All sources mentioned in the text, along with their locations.
    static func mentions(in text: String) -> [(range: Range<String.Index>, ids: [String])] {
        var found: [(Range<String.Index>, [String])] = []
        for alias in aliases {
            guard let regex = try? NSRegularExpression(pattern: #"(?<![\p{L}\d])(?:"# + alias.pattern + #")(?![\p{L}\d])"#, options: [.caseInsensitive]) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range, in: text) { found.append((range, alias.ids)) }
            }
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }
}

/// Which sources Nook may use. Automatic = everything enabled; Nook decides what is relevant.
struct SourceScope: Equatable, Codable {
    enum Mode: String, Codable { case automatic, only }

    var mode: Mode = .automatic
    /// In `.only` mode: only these sources.
    var included: Set<String> = []
    /// Never use these sources, even automatically.
    var excluded: Set<String> = []
    /// Mentioned in the query without restriction ("search Slack and GitHub"): prioritize searching there, send full context.
    var focus: Set<String> = []
    /// Accounts this chat may not use ("github.werk"), on top of the sources above. Optional: chats saved before
    /// accounts existed have none.
    var excludedAccounts: Set<String>?

    static let automatic = SourceScope()

    var isRestricted: Bool { mode == .only || !excluded.isEmpty || !(excludedAccounts ?? []).isEmpty }

    /// Whether this chat may use that account. A source that is not allowed allows none of its accounts.
    func allowsAccount(_ id: String) -> Bool {
        let service = id.split(separator: ".").first.map(String.init) ?? id
        return allows(service) && !(excludedAccounts ?? []).contains(id)
    }

    func allows(_ id: String) -> Bool {
        if excluded.contains(id) { return false }
        if mode == .only { return included.contains(id) }
        return true
    }

    /// Whether this tool is permitted. Tools without a source (charts, open app) are always allowed.
    func allowsTool(_ name: String) -> Bool {
        guard let source = SourceCatalog.source(forTool: name) else { return true }
        return allows(source)
    }

    /// The chat picker selection combined with what the query specifies. The query takes precedence, but a source disabled
    /// in the picker by the user is not re-enabled simply by being mentioned in the query.
    func merged(with request: SourceScope?) -> SourceScope {
        guard let request else { return self }
        var result = self
        if request.mode == .only {
            let base = mode == .only ? included : nil
            result.mode = .only
            result.included = base.map { request.included.intersection($0) } ?? request.included
            if result.included.isEmpty { result.included = request.included.subtracting(excluded) }
        }
        result.excluded.formUnion(request.excluded)
        result.focus = request.focus.subtracting(result.excluded)
        return result
    }

    /// The same scope without the sources that may only be read by a brain on this Mac. Used while an external brain
    /// answers: those sources are out of the context, their tools are invisible and a question cannot bring them back.
    func keepingLocal(_ privateSources: Set<String>) -> SourceScope {
        guard !privateSources.isEmpty else { return self }
        var result = self
        result.excluded.formUnion(privateSources)
        result.included.subtract(privateSources)
        result.focus.subtract(privateSources)
        return result
    }

    /// Short description for chat display, e.g. "Alleen Agenda en Mail" or "Zonder Scherm".
    func label(title: (String) -> String = SourceCatalog.title) -> String {
        var parts: [String] = []
        if mode == .only {
            let names = Self.uniqueTitles(included, title: title)
            parts.append("Alleen " + Self.list(names))
        }
        if !excluded.isEmpty {
            parts.append("Zonder " + Self.list(Self.uniqueTitles(excluded, title: title)))
        }
        return parts.isEmpty ? "Automatisch" : parts.joined(separator: " · ")
    }

    private static func uniqueTitles(_ ids: Set<String>, title: (String) -> String) -> [String] {
        var seen = Set<String>()
        let order = SourceCatalog.all.map(\.id)
        return ids.sorted { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }
            .map(title).filter { seen.insert($0).inserted }
    }

    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " en " + names.last!
    }

    // MARK: Parsing from query

    private static let onlyCue = #"\b(alleen|uitsluitend|enkel|only|exclusively|nur|ausschlie(ß|ss)lich)\b"#
    private static let exceptCue = #"\b(zonder|behalve|exclusief|without|except|excluding|ohne|au(ß|ss)er)\b"#
    private static let negationCue = #"\b(niet|geen|nooit|not|don'?t|never|nicht|kein\w*|nie)\b"#
    private static let useVerb = #"\b(gebruik\w*|zoek\w*|doorzoek\w*|kijk\w*|lees\w*|use|using|search\w*|look\w*|read\w*|check\w*|benutz\w*|verwend\w*|durchsuch\w*|such\w*|schau\w*)\b"#
    private static let allCue = #"\b(alle|all)\b[^.;!?]{0,25}\b(bronnen|sources|quellen)\b"#

    /// Extracts a scope restriction from the query: "only my calendar and mail", "search Slack and GitHub, but not my screen",
    /// "use all sources". Returns nil if the query mentions no sources.
    static func parse(_ text: String) -> SourceScope? {
        var scope = SourceScope()
        var said = false
        if text.range(of: allCue, options: [.regularExpression, .caseInsensitive]) != nil { said = true }

        for clause in clauses(text) {
            let mentions = SourceCatalog.mentions(in: clause)
            guard !mentions.isEmpty else { continue }
            let only = clause.range(of: onlyCue, options: [.regularExpression, .caseInsensitive])
            let except = clause.range(of: exceptCue, options: [.regularExpression, .caseInsensitive])
            let negations = ranges(of: negationCue, in: clause)
            let verbs = ranges(of: useVerb, in: clause)
            // "do not use …", "niet gebruiken": the negation applies to usage itself.
            let negatedVerb = negations.contains { negation in
                verbs.contains { verb in
                    let gap = verb.lowerBound > negation.upperBound
                        ? clause.distance(from: negation.upperBound, to: verb.lowerBound)
                        : (negation.lowerBound > verb.upperBound ? clause.distance(from: verb.upperBound, to: negation.lowerBound) : 99)
                    return gap <= 14
                }
            }

            for mention in mentions {
                let ids = Set(mention.ids)
                // "niet in mijn mail", "not my screen", "geen scherm", or "gebruik mijn scherm niet".
                let negatedMention = negations.contains { negation in
                    if negation.upperBound <= mention.range.lowerBound {
                        return clause.distance(from: negation.upperBound, to: mention.range.lowerBound) <= 16
                    }
                    if negation.lowerBound >= mention.range.upperBound, !verbs.isEmpty {
                        return clause.distance(from: mention.range.upperBound, to: negation.lowerBound) <= 12
                    }
                    return false
                }
                if let except, except.lowerBound < mention.range.lowerBound {
                    scope.excluded.formUnion(ids)
                } else if negatedVerb || negatedMention {
                    scope.excluded.formUnion(ids)
                } else if let only, only.lowerBound < mention.range.lowerBound {
                    scope.mode = .only
                    scope.included.formUnion(ids)
                } else {
                    scope.focus.formUnion(ids)
                    continue
                }
                said = true
            }
        }
        scope.included.subtract(scope.excluded)
        scope.focus.subtract(scope.excluded)
        if scope.mode == .only && scope.included.isEmpty { scope.mode = .automatic }
        guard said || !scope.focus.isEmpty else { return nil }
        return scope
    }

    private static func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// Sentence clauses: a restriction applies within a sentence or clause ("…, but not my screen").
    private static func clauses(_ text: String) -> [String] {
        let marked = text.replacingOccurrences(
            of: #"[.;!?\n]|,|\b(maar|but|aber|en daarna|and then|dann)\b"#,
            with: "\u{1F}", options: [.regularExpression, .caseInsensitive]
        )
        return marked.split(separator: "\u{1F}").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Which sources should be sent in full for this query. The rest are sent as a single summary line ("Mail: 12 unread,
/// search with search_mail"), so the brain knows they exist without sending full content on every turn.
enum SourceRouter {
    /// Always sent in full: compact and almost always useful for understanding the day. Reminders are not: a list of
    /// to-dos in every prompt pulls a small model off the question ("stuur Arjan een bericht"), so they come along only
    /// when the question is about reminders, tasks or the day.
    static let core: Set<String> = ["calendar", SourceCatalog.loops]

    private static let intents: [(pattern: String, ids: [String])] = [
        (#"\w*mail\w*|inbox|postvak\w*|ongelezen|unread|ungelesen|niet\W+(\w+\W+){0,2}gelezen|not\W+(\w+\W+){0,2}read|afzender\w*|senders?|bericht\w*|messages?|antwoord\w*|reply|replies|schreef|schrijf|wrote|follow.?up|opvolg\w*|toegezegd|beloofd|commitments?|afgesproken|agreed|discuss\w*|besproken|gesprek"#, ["mail", "customsources"]),
        (#"bericht\w*|messages?|chat\w*|gesprek\w*|appje\w*|ge-?appt|appte\w*|sms\w*|imessage|whats-?app|zei|zegt|stuurde|said|texted|toegezegd|beloofd|afgesproken"#, ["messages", "whatsapp"]),
        (#"tabs?|tabblad\w*|pagina|page|website|site|artikel|article|browser|gelezen|las ik"#, ["browser"]),
        (#"terminal|shell|commando|command\b|npm |yarn |pip |brew |git |draai |run |voer .{0,20}uit|installeer|install\b"#, ["terminal"]),
        (#"notitie\w*|notes?|memo'?s?|aantekening\w*"#, ["notes", "bear"]),
        (#"traag|langzaam|trage mac|hangt|vastloopt|batterij\w*|accu\w*|geheugen|werkgeheugen|\bram\b|processor|\bcpu\b|ventilator|schijfruimte|harde schijf|schijf vol\w*|opslag\w*|vrije ruimte|slow|battery|memory|disk space|storage|fan\b|langsam|akku|speicher|festplatte"#, ["system"]),
        (#"call\w*|meeting\w*|vergader\w*|overleg\w*|gesprek\w*|besproken|afgesproken|zei .{0,20}in de|notulen|to-?do'?s? uit|besprechung\w*"#, ["callnotes"]),
        (#"taken|takenlijst|to-?do'?s?|tasks?|projecten|projects?"#, ["things"]),
        (#"herinner\w*|reminders?|remind|erinner\w*|taken|taak|takenlijst|to-?do'?s?|tasks?|aufgabe\w*|moet ik|vergeet|vergeten|forget|deadline\w*|planning|mijn dag|my day|vandaag|today|morgen|tomorrow|heute|week|agenda"#, ["reminders"]),
        (#"contact\w*|telefoon\w*|telefoonnummer|e-?mailadres|adresboek|address book"#, ["contacts"]),
        (#"bestand\w*|files?|document\w*|pdf|rapport|report|requirements?|eisen|specificatie\w*|spec\b|offerte|contract"#, ["files", "notion"]),
        (#"code|repo\w*|pull|pr\b|prs\b|issues?|ci\b|build|merge|review|commit\w*|bug\w*|release|requirements?"#, ["github"]),
        (#"deploy\w*|vercel|productie|production|site live"#, ["vercel"]),
        (#"omzet|revenue|betaling\w*|payments?|stripe|klant\w*|customers?|facturen|invoices?|abonnement\w*|subscriptions?"#, ["stripe"]),
        (#"notion|wiki|kennisbank|knowledge|docs?\b"#, ["notion"]),
        (#"boeking\w*|bookings?|cal\.com"#, ["calcom"]),
        (#"workflows?|automatiser\w*|automation|n8n"#, ["n8n"]),
        (#"resend|verzonden mail|deliverability|bounce\w*"#, ["resend"]),
        (#"klembord|clipboard|gekopieerd|copied|plakken"#, ["clipboard"]),
        (#"slack|teams|discord|telegram|kanaal|channel"#, ["customsources"])
    ]

    /// Broad queries ("summarize my week", "what happened") may consult all available sources.
    private static let broad = #"samenvat\w*|vat\b.*samen|overzicht|summar\w*|zusammenfass\w*|alles|everything|all (my|of)|wat is er gebeurd|what happened|deze week|this week|diese woche|bereid\w* .*voor|prepare|voorbereid\w*"#

    static func relevant(to text: String, scope: SourceScope, active: Set<String>) -> Set<String> {
        let allowed = active.filter { scope.allows($0) }
        if text.range(of: broad, options: [.regularExpression, .caseInsensitive]) != nil { return allowed }
        var wanted = core.union(scope.focus)
        if scope.mode == .only { wanted.formUnion(scope.included) }
        for intent in intents + SourceCatalog.registeredIntents where text.range(of: #"(?<![\p{L}\d])(?:"# + intent.pattern + #")"#, options: [.regularExpression, .caseInsensitive]) != nil {
            wanted.formUnion(intent.ids)
        }
        for mention in SourceCatalog.mentions(in: text) { wanted.formUnion(mention.ids) }
        return allowed.intersection(wanted)
    }
}

/// What a connection can do, in plain language, for settings: how it connects and what read and write actions are available.
enum SourceCapabilities {
    private static let phrases: [String: String] = [
        "list_events": "afspraken lezen", "check_availability": "beschikbaarheid in alle agenda's",
        "create_event": "afspraak maken", "update_event": "afspraak aanpassen", "delete_event": "afspraak verwijderen",
        "create_reminder": "herinnering maken", "complete_reminder": "herinnering afvinken", "delete_reminder": "herinnering verwijderen",
        "list_reminders": "herinneringen bekijken", "search_reminders": "herinneringen zoeken",
        "list_notes": "notities bekijken", "search_notes": "notities zoeken", "read_note": "notitie lezen", "create_note": "notitie maken",
        "search_messages": "alle gesprekken doorzoeken", "read_messages": "gesprek lezen", "search_whatsapp": "alle chats doorzoeken",
        "read_whatsapp": "chat lezen", "whatsapp_live": "live chats via je telefoon", "whatsapp_send": "WhatsApp-bericht sturen",
        "search_call_notes": "opgenomen gesprekken doorzoeken", "read_call_note": "gesprek lezen", "mac_status": "processor, geheugen, batterij en schijf", "messages_open_chats": "ongelezen en onbeantwoorde gesprekken", "whatsapp_open_chats": "ongelezen en onbeantwoorde chats", "search_bear": "notities doorzoeken", "read_bear": "notitie lezen", "search_things": "taken en projecten doorzoeken",
        "search_mail": "mail zoeken (inbox en verzonden)", "read_mail": "hele mail lezen", "mail_unread": "ongelezen mail tellen", "inbox_mail": "recente mail lezen", "compose_mail": "mailconcept (jij verstuurt)",
        "search_files": "bestanden zoeken", "read_file": "document lezen",
        "read_browser_tab": "geopende webpagina lezen", "read_open_app": "app naast de chat lezen",
        "read_screen": "scherm lezen", "read_app": "een geopende of gesloten app lezen",
        "list_running_apps": "draaiende apps zien", "get_active_app": "actieve app zien",
        "search_contacts": "contacten zoeken", "read_clipboard": "klembord lezen",
        "list_open_loops": "open punten lezen", "add_open_loop": "open punt toevoegen", "complete_open_loop": "open punt afronden",
        "remember": "iets onthouden", "forget": "iets vergeten", "recall_memory": "geheugen doorzoeken",
        "search_web": "web doorzoeken", "read_webpage": "webpagina lezen", "web_search": "web doorzoeken", "get_weather": "weer opvragen",
        "read_source": "API lezen (GET)", "send_to_source": "bericht of webhook sturen",
        "github_overview": "je PR's en reviews", "github_pr_details": "PR met diff lezen", "github_search": "issues en PR's zoeken",
        "github_issue_details": "issue lezen", "github_review_pr": "PR beoordelen", "github_comment_pr": "reageren op PR",
        "github_merge_pr": "PR samenvoegen", "github_close_pr": "PR sluiten", "github_create_issue": "issue maken",
        "github_comment_issue": "reageren op issue", "github_update_issue": "issue bijwerken",
        "vercel_deployments": "deployments lezen", "stripe_payments": "betalingen lezen", "notion_search": "pagina's zoeken",
        "notion_read_page": "pagina lezen", "calcom_bookings": "boekingen lezen", "n8n_status": "workflows lezen",
        "resend_overview": "verzonden mail lezen"
    ]

    static func kindLabel(_ kind: SourceKind) -> String {
        switch kind {
        case .builtIn: return "Op je Mac"
        case .oauth: return "Inloggen (OAuth)"
        case .apiKey: return "API-sleutel"
        case .custom: return "Eigen API of webhook"
        case .web: return "Internet"
        case .nook: return "Nook"
        }
    }

    /// Read and write capabilities for a source, derived from current tools (name → whether it is an action).
    static func describe(_ sourceID: String, tools: [(name: String, isAction: Bool)]) -> (reads: [String], writes: [String]) {
        var reads: [String] = []
        var writes: [String] = []
        for tool in tools where SourceCatalog.source(forTool: tool.name) == sourceID {
            let phrase = phrases[tool.name] ?? tool.name
            if tool.isAction {
                if !writes.contains(phrase) { writes.append(phrase) }
            } else if !reads.contains(phrase) {
                reads.append(phrase)
            }
        }
        return (reads, writes)
    }

    /// Single line summary: "API key · reading: read payments · writing: —".
    static func line(_ sourceID: String, tools: [(name: String, isAction: Bool)]) -> String {
        let kind = SourceCatalog.descriptor(sourceID).map { kindLabel($0.kind) } ?? ""
        let ops = describe(sourceID, tools: tools)
        var parts = [kind].filter { !$0.isEmpty }
        if !ops.reads.isEmpty { parts.append("lezen: " + ops.reads.joined(separator: ", ")) }
        parts.append(ops.writes.isEmpty ? "schrijven: niets" : "schrijven (na jouw OK): " + ops.writes.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }
}

/// Lookups Nook runs itself before asking the model, for every source and every app the question is about, so the
/// answer never depends on a (small, local) model deciding to call a tool. General: for each relevant source Nook runs
/// one read tool that needs no input; the hints below only pick the best input when a source has a choice.
enum Prefetch {
    struct Call {
        let tool: String
        let input: [String: Any]
    }

    /// A read tool Nook could run: its name, the source it belongs to and the inputs it requires.
    struct Available {
        let name: String
        let source: String
        let required: [String]
        /// The text field a search goes in ("query", "q"…), when the tool has one.
        var query: String? = nil

        /// The field of a schema that takes a search text: a string property named like a query.
        static func queryField(_ schema: [String: Any]) -> String? {
            guard let properties = schema["properties"] as? [String: Any] else { return nil }
            for name in ["query", "q", "search", "term", "keyword", "keywords", "text"] {
                if let field = properties[name] as? [String: Any], (field["type"] as? String) == "string" { return name }
            }
            return nil
        }
    }

    /// The question asks for the newest or unread items of this source, so its overview helps even next to a search.
    static func prefersListing(_ source: String, _ text: String) -> Bool {
        switch source {
        case "mail": return matches(unread, text) || matches(reply, text) || matches(pending, text)
        case "notes": return matches(#"recent\w*|laatst\w*|nieuwst\w*|latest|newest|neueste?n?|letzte?n?"#, text)
        case "messages", "whatsapp": return matches(unread, text) || matches(reply, text) || matches(pending, text)
        default: return false
        }
    }

    /// Sources whose data is always in the context in full already.
    static let inContext: Set<String> = SourceRouter.core

    private static let unread = #"ongelezen|unread|ungelesen|niet\W+(\w+\W+){0,2}gelezen|not\W+(\w+\W+){0,2}read"#
    private static let reply = #"beantwoord\w*|antwoord\w*|reageer|reageren|terugmail\w*|terugschrijv\w*|reply|respond|answer|follow.?up|opvolg\w*"#
    /// Chats still waiting for something: "openstaan", "open chats", "nog niet gereageerd", "pending", "offen".
    static let pending = #"open ?staa?n\w*|openstaand\w*|open (chats?|gesprekk?e?n?|berichten|appjes?|conversations?|threads?|messages?)|onbeantwoord\w*|unanswered|pending|outstanding|waiting|wacht\w* (op|nog)|nog (niet )?(gereageerd|geantwoord|beantwoord|teruggeappt|teruggestuurd)|unbeantwortet\w*|offene?n? (chats?|nachrichten)"#

    /// Best input for a few tools, by what the question asks.
    private static func hint(_ tool: String, _ text: String) -> (rank: Int, input: [String: Any]) {
        switch tool {
        case "mail_unread": return (matches(unread, text) ? 0 : 9, [:])
        case "inbox_mail":
            return matches(reply, text) || matches(pending, text) ? (1, ["days": 14, "unanswered_only": true]) : (2, ["days": 7])
        case "whatsapp_open_chats", "messages_open_chats":
            return (matches(unread, text) || matches(reply, text) || matches(pending, text) ? 0 : 2, [:])
        // The linked phone is live: its overview goes before what WhatsApp on this Mac has synced.
        case "whatsapp_live": return (matches(unread, text) || matches(reply, text) || matches(pending, text) ? 0 : 1, [:])
        case "list_notes": return (1, ["limit": 8])
        case "list_reminders": return (1, [:])
        case "read_browser_tab": return (1, [:])
        default: return (5, [:])
        }
    }

    /// One call per relevant source (at most `limit`), using a read tool without required inputs.
    static func calls(for text: String, relevant: Set<String>, available: [Available], limit: Int = 4) -> [Call] {
        var calls: [Call] = []
        let order = SourceCatalog.all.map(\.id)
        for source in relevant.subtracting(inContext).sorted(by: { (order.firstIndex(of: $0) ?? 99) < (order.firstIndex(of: $1) ?? 99) }) {
            let candidates = available.filter { $0.source == source && $0.required.isEmpty }
            let best = candidates.enumerated().min { a, b in
                let ha = hint(a.element.name, text).rank, hb = hint(b.element.name, text).rank
                return ha != hb ? ha < hb : a.offset < b.offset
            }
            guard let pick = best?.element else { continue }
            calls.append(Call(tool: pick.name, input: hint(pick.name, text).input))
        }
        return Array(calls.prefix(limit))
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: #"(?<![\p{L}\d])(?:"# + pattern + ")", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

