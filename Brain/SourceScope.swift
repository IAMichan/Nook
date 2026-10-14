import Foundation

// Welke bronnen Nook bij een vraag gebruikt. Drie dingen lopen hier samen:
// - de catalogus: welke bronnen er zijn, wat voor soort koppeling het is en welke tools erbij horen;
// - de reikwijdte (SourceScope): wat de gebruiker toestaat, met de bronkiezer in de chat of in de vraag zelf
//   ("alleen mijn agenda en mail", "zonder mijn scherm");
// - de routering (SourceRouter): welke toegestane bronnen voor deze vraag de moeite waard zijn om volledig mee te sturen.
// Alles hier is gewone Foundation-code zonder UI, zodat het los te testen is.

/// Wat voor soort koppeling een bron is. Zo kan de gebruiker zien hoe iets gekoppeld is en wat dat betekent.
enum SourceKind: String, Codable, CaseIterable {
    /// Op je Mac: Agenda, Herinneringen, Mail, browser, bestanden, klembord, scherm.
    case builtIn
    /// Inloggen bij de dienst zelf (GitHub).
    case oauth
    /// Een sleutel die je zelf plakt (Stripe, Vercel, Notion…).
    case apiKey
    /// Een eigen bron met een web-API of webhook.
    case custom
    /// Het open internet.
    case web
    /// Nooks eigen gegevens (open punten).
    case nook
}

struct SourceDescriptor: Equatable {
    let id: String
    let title: String
    let kind: SourceKind
}

enum SourceCatalog {
    /// Pseudo-bronnen die geen koppeling zijn maar wel aan of uit kunnen per vraag.
    static let screen = "screen"
    static let web = "web"
    static let loops = "loops"

    static let all: [SourceDescriptor] = [
        SourceDescriptor(id: "calendar", title: "Agenda", kind: .builtIn),
        SourceDescriptor(id: "icalfeeds", title: "Andere agenda's", kind: .apiKey),
        SourceDescriptor(id: "calcom", title: "Cal.com", kind: .apiKey),
        SourceDescriptor(id: "reminders", title: "Herinneringen", kind: .builtIn),
        SourceDescriptor(id: loops, title: "Open punten", kind: .nook),
        SourceDescriptor(id: "mail", title: "Mail", kind: .builtIn),
        SourceDescriptor(id: "browser", title: "Browser", kind: .builtIn),
        SourceDescriptor(id: "files", title: "Bestanden", kind: .builtIn),
        SourceDescriptor(id: "clipboard", title: "Klembord", kind: .builtIn),
        SourceDescriptor(id: screen, title: "Scherm", kind: .builtIn),
        SourceDescriptor(id: "github", title: "GitHub", kind: .oauth),
        SourceDescriptor(id: "vercel", title: "Vercel", kind: .apiKey),
        SourceDescriptor(id: "stripe", title: "Stripe", kind: .apiKey),
        SourceDescriptor(id: "notion", title: "Notion", kind: .apiKey),
        SourceDescriptor(id: "n8n", title: "n8n", kind: .apiKey),
        SourceDescriptor(id: "resend", title: "Resend", kind: .apiKey),
        SourceDescriptor(id: "portfolio", title: "Crypto", kind: .apiKey),
        SourceDescriptor(id: "customsources", title: "Eigen bronnen", kind: .custom),
        SourceDescriptor(id: web, title: "Web", kind: .web)
    ]

    static func descriptor(_ id: String) -> SourceDescriptor? {
        all.first { $0.id == id }
    }

    static func title(_ id: String) -> String {
        descriptor(id)?.title ?? id
    }

    /// Tools die bij een bron horen. Tools zonder bron (grafiek, app openen, muziek…) mogen altijd.
    private static let exactTools: [String: String] = [
        "list_events": "calendar", "create_event": "calendar", "update_event": "calendar",
        "check_availability": "calendar",
        "create_reminder": "reminders", "complete_reminder": "reminders",
        "search_mail": "mail", "mail_unread": "mail",
        "search_files": "files", "read_file": "files",
        "read_screen": screen,
        "list_open_loops": loops, "add_open_loop": loops, "complete_open_loop": loops,
        "search_web": web, "read_webpage": web, "web_search": web,
        "read_source": "customsources", "send_to_source": "customsources",
        "vercel_deployments": "vercel", "stripe_payments": "stripe", "notion_search": "notion", "notion_read_page": "notion",
        "calcom_bookings": "calcom", "n8n_status": "n8n", "resend_overview": "resend",
        "portfolio_overview": "portfolio"
    ]

    /// Apps die bij een bron horen: werk je daar net in, dan gaat een vraag waarschijnlijk over die bron.
    private static let bundles: [String: String] = [
        "com.apple.mail": "mail", "com.microsoft.Outlook": "mail", "com.readdle.smartemail-Mac": "mail",
        "com.apple.iCal": "calendar", "com.flexibits.fantastical2.mac": "calendar",
        "com.apple.reminders": "reminders",
        "com.apple.Safari": "browser", "com.google.Chrome": "browser", "company.thebrowser.Browser": "browser",
        "com.brave.Browser": "browser", "com.microsoft.edgemac": "browser",
        "com.apple.finder": "files", "com.apple.Preview": "files",
        "notion.id": "notion", "com.github.GitHubClient": "github",
        "com.tinyspeck.slackmacgap": "customsources", "com.microsoft.teams2": "customsources"
    ]

    static func source(forBundle bundleID: String) -> String? {
        bundles[bundleID]
    }

    static func source(forTool name: String) -> String? {
        if let exact = exactTools[name] { return exact }
        if name.hasPrefix("github_") { return "github" }
        return nil
    }

    /// Hoe de gebruiker een bron noemt (Nederlands, Engels, Duits). Eén woord kan meerdere bronnen dekken:
    /// "agenda" is Apple Agenda, je ICS-agenda's en Cal.com samen.
    static let aliases: [(pattern: String, ids: [String])] = [
        (#"agenda'?s?|kalender\w*|calendars?|ical"#, ["calendar", "icalfeeds", "calcom"]),
        (#"cal\.com"#, ["calcom"]),
        (#"herinnering\w*|reminders?|erinnerung\w*"#, ["reminders"]),
        (#"taken|takenlijst|tasks?|to-?do'?s?|aufgaben"#, ["reminders", loops]),
        (#"open punten|open loops?"#, [loops]),
        (#"e-?mails?|mail|mailbox|inbox|postvak\w*|posteingang"#, ["mail"]),
        (#"browser\w*|tabs?|tabblad\w*|safari|chrome"#, ["browser"]),
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
        (#"crypto|portfolio|bitcoin"#, ["portfolio"]),
        (#"slack|teams|discord|telegram|eigen bronn?e?n?|custom sources?"#, ["customsources"])
    ]

    /// Alle bronnen die in de tekst genoemd worden, met waar ze staan.
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

/// Welke bronnen Nook mag gebruiken. Automatisch = alles wat aan staat, Nook kiest zelf wat relevant is.
struct SourceScope: Equatable, Codable {
    enum Mode: String, Codable { case automatic, only }

    var mode: Mode = .automatic
    /// Bij `.only`: alleen deze bronnen.
    var included: Set<String> = []
    /// Nooit deze bronnen, ook niet automatisch.
    var excluded: Set<String> = []
    /// Genoemd in de vraag zonder beperking ("kijk in Slack en GitHub"): eerst daar zoeken, volledig meesturen.
    var focus: Set<String> = []

    static let automatic = SourceScope()

    var isRestricted: Bool { mode == .only || !excluded.isEmpty }

    func allows(_ id: String) -> Bool {
        if excluded.contains(id) { return false }
        if mode == .only { return included.contains(id) }
        return true
    }

    /// Mag deze tool? Tools zonder bron (grafiek, app openen) altijd.
    func allowsTool(_ name: String) -> Bool {
        guard let source = SourceCatalog.source(forTool: name) else { return true }
        return allows(source)
    }

    /// De keuze in de chat plus wat de vraag zelf zegt. Wat de vraag zegt, gaat voor, maar een bron die de gebruiker
    /// in de bronkiezer uitzette, komt niet terug doordat de vraag hem noemt.
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

    /// Korte uitleg voor in de chat, bijvoorbeeld "Alleen Agenda en Mail" of "Zonder Scherm".
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

    // MARK: Uit de vraag halen

    private static let onlyCue = #"\b(alleen|uitsluitend|enkel|only|exclusively|nur|ausschlie(ß|ss)lich)\b"#
    private static let exceptCue = #"\b(zonder|behalve|exclusief|without|except|excluding|ohne|au(ß|ss)er)\b"#
    private static let negationCue = #"\b(niet|geen|nooit|not|don'?t|never|nicht|kein\w*|nie)\b"#
    private static let useVerb = #"\b(gebruik\w*|zoek\w*|doorzoek\w*|kijk\w*|lees\w*|use|using|search\w*|look\w*|read\w*|check\w*|benutz\w*|verwend\w*|durchsuch\w*|such\w*|schau\w*)\b"#
    private static let allCue = #"\b(alle|all)\b[^.;!?]{0,25}\b(bronnen|sources|quellen)\b"#

    /// Haalt een beperking uit de vraag: "alleen mijn agenda en mail", "zoek in Slack en GitHub, maar niet op mijn scherm",
    /// "gebruik alle bronnen". Geeft nil als de vraag niets over bronnen zegt.
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
            // "do not use …", "niet gebruiken": de ontkenning hoort bij het gebruiken zelf.
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
                // "niet in mijn mail", "not my screen", "geen scherm", of "gebruik mijn scherm niet".
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

    /// Stukken zin: een beperking geldt binnen een zin of bijzin ("…, maar niet mijn scherm").
    private static func clauses(_ text: String) -> [String] {
        let marked = text.replacingOccurrences(
            of: #"[.;!?\n]|,|\b(maar|but|aber|en daarna|and then|dann)\b"#,
            with: "\u{1F}", options: [.regularExpression, .caseInsensitive]
        )
        return marked.split(separator: "\u{1F}").map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// Welke bronnen voor deze vraag volledig mee moeten. De rest krijgt het brein als één regel ("Mail: 12 ongelezen,
/// doorzoek met search_mail"), zodat het weet dat ze er zijn zonder dat alles bij elke vraag meegaat.
enum SourceRouter {
    /// Altijd volledig: klein en bijna altijd nuttig om de dag te snappen.
    static let core: Set<String> = ["calendar", "reminders", SourceCatalog.loops]

    private static let intents: [(pattern: String, ids: [String])] = [
        (#"\w*mail\w*|inbox|bericht\w*|messages?|antwoord\w*|reply|replies|schreef|schrijf|wrote|follow.?up|opvolg\w*|toegezegd|beloofd|commitments?|afgesproken|agreed|discuss\w*|besproken|gesprek"#, ["mail", "customsources"]),
        (#"tabs?|tabblad\w*|pagina|page|website|site|artikel|article|browser|gelezen|las ik"#, ["browser"]),
        (#"bestand\w*|files?|document\w*|pdf|rapport|report|notities|notes|requirements?|eisen|specificatie\w*|spec\b|offerte|contract"#, ["files", "notion"]),
        (#"code|repo\w*|pull|pr\b|prs\b|issues?|ci\b|build|merge|review|commit\w*|bug\w*|release|requirements?"#, ["github"]),
        (#"deploy\w*|vercel|productie|production|site live"#, ["vercel"]),
        (#"omzet|revenue|betaling\w*|payments?|stripe|klant\w*|customers?|facturen|invoices?|abonnement\w*|subscriptions?"#, ["stripe"]),
        (#"notion|wiki|kennisbank|knowledge|docs?\b"#, ["notion"]),
        (#"boeking\w*|bookings?|cal\.com"#, ["calcom"]),
        (#"workflows?|automatiser\w*|automation|n8n"#, ["n8n"]),
        (#"resend|verzonden mail|deliverability|bounce\w*"#, ["resend"]),
        (#"crypto|bitcoin|portfolio|koers\w*|wallet"#, ["portfolio"]),
        (#"klembord|clipboard|gekopieerd|copied|plakken"#, ["clipboard"]),
        (#"slack|teams|discord|telegram|kanaal|channel"#, ["customsources"])
    ]

    /// Brede vragen ("vat mijn week samen", "wat is er gebeurd") mogen overal kijken.
    private static let broad = #"samenvat\w*|vat\b.*samen|overzicht|summar\w*|zusammenfass\w*|alles|everything|all (my|of)|wat is er gebeurd|what happened|deze week|this week|diese woche|bereid\w* .*voor|prepare|voorbereid\w*"#

    /// `frontApp`: de bron van de app waarin de gebruiker net werkte (Mail, Safari…); die gaat altijd volledig mee.
    static func relevant(to text: String, scope: SourceScope, active: Set<String>, frontApp: String? = nil) -> Set<String> {
        let allowed = active.filter { scope.allows($0) }
        if text.range(of: broad, options: [.regularExpression, .caseInsensitive]) != nil { return allowed }
        var wanted = core.union(scope.focus)
        if let frontApp { wanted.insert(frontApp) }
        if scope.mode == .only { wanted.formUnion(scope.included) }
        for intent in intents where text.range(of: #"(?<![\p{L}\d])(?:"# + intent.pattern + #")"#, options: [.regularExpression, .caseInsensitive]) != nil {
            wanted.formUnion(intent.ids)
        }
        for mention in SourceCatalog.mentions(in: text) { wanted.formUnion(mention.ids) }
        return allowed.intersection(wanted)
    }
}

/// Wat een koppeling kan, in gewone woorden, voor de instellingen: hoe hij gekoppeld is en welke lees- en schrijfacties er zijn.
enum SourceCapabilities {
    private static let phrases: [String: String] = [
        "list_events": "afspraken lezen", "check_availability": "beschikbaarheid in alle agenda's",
        "create_event": "afspraak maken", "update_event": "afspraak aanpassen",
        "create_reminder": "herinnering maken", "complete_reminder": "herinnering afvinken",
        "search_mail": "mail zoeken (inbox en verzonden)", "mail_unread": "ongelezen mail tellen", "compose_mail": "mailconcept (jij verstuurt)",
        "search_files": "bestanden zoeken", "read_file": "document lezen", "read_screen": "scherm lezen",
        "list_open_loops": "open punten lezen", "add_open_loop": "open punt toevoegen", "complete_open_loop": "open punt afronden",
        "search_web": "web doorzoeken", "read_webpage": "webpagina lezen", "web_search": "web doorzoeken",
        "read_source": "API lezen (GET)", "send_to_source": "bericht of webhook sturen",
        "github_overview": "je PR's en reviews", "github_pr_details": "PR met diff lezen", "github_search": "issues en PR's zoeken",
        "github_issue_details": "issue lezen", "github_review_pr": "PR beoordelen", "github_comment_pr": "reageren op PR",
        "github_merge_pr": "PR samenvoegen", "github_close_pr": "PR sluiten", "github_create_issue": "issue maken",
        "github_comment_issue": "reageren op issue", "github_update_issue": "issue bijwerken",
        "vercel_deployments": "deployments lezen", "stripe_payments": "betalingen lezen", "notion_search": "pagina's zoeken",
        "notion_read_page": "pagina lezen", "calcom_bookings": "boekingen lezen", "n8n_status": "workflows lezen",
        "resend_overview": "verzonden mail lezen", "portfolio_overview": "portfolio lezen"
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

    /// Lees- en schrijfacties voor een bron, uit de tools die er nu zijn (naam → is het een actie).
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

    /// Eén regel: "API-sleutel · lezen: betalingen lezen · schrijven: —".
    static func line(_ sourceID: String, tools: [(name: String, isAction: Bool)]) -> String {
        let kind = SourceCatalog.descriptor(sourceID).map { kindLabel($0.kind) } ?? ""
        let ops = describe(sourceID, tools: tools)
        var parts = [kind].filter { !$0.isEmpty }
        if !ops.reads.isEmpty { parts.append("lezen: " + ops.reads.joined(separator: ", ")) }
        parts.append(ops.writes.isEmpty ? "schrijven: niets" : "schrijven (na jouw OK): " + ops.writes.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }
}
