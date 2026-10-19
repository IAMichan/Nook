import Foundation

/// Nook's own research before the model answers. A small local model rarely searches well by itself: it calls one tool
/// with the whole question as search term, reads only the first lines of a hit, or answers from the titles of the eight
/// most recent notes. So Nook does that work on the Mac, the same way for every model and every source:
///
/// 1. **Terms**: the words that carry the question ("wat staat er in mijn notitie over de verbouwing?" → "verbouwing"),
///    without filler, source names or dates; a follow-up ("en het budget?") keeps the terms of the question before.
/// 2. **Search**: every relevant source is searched with those terms (notes, mail, files, Notion, GitHub, the web, MCP
///    servers…). A question that names no source is searched everywhere Nook can search.
/// 3. **Read**: the hits of all sources are ranked by how well they match, and the best ones are opened in full with
///    the source's own read tool (read_note, read_mail, read_file, notion_read_page, github_issue_details, read_webpage).
///
/// The model then answers from the documents themselves. Everything here is plain Foundation, so it is tested in isolation.
enum Research {
    // MARK: Terms

    struct Terms: Equatable {
        /// Words that carry the meaning of the question, most specific (longest) first.
        var words: [String] = []
        /// Phrases the user put in quotes, kept whole.
        var phrases: [String] = []
        /// Capitalized words in the question, most likely names ("Lisa", "Apollo").
        var names: [String] = []
        /// Some of the words came from the previous question (a follow-up).
        var inherited = false

        var isEmpty: Bool { words.isEmpty && phrases.isEmpty }

        /// Everything to match on, phrases first.
        var all: [String] { phrases + words.filter { word in !phrases.contains { $0.contains(word) } } }

        /// Text for a search tool: phrases first, then the most specific words.
        func query(limit: Int = 4) -> String {
            Array(all.prefix(limit)).joined(separator: " ")
        }
    }

    /// Words that never make a good search term: filler, question words, verbs of asking, source names and dates
    /// (Dutch, English, German). Dates belong to the calendar, not to a search in notes.
    static let stopwords: Set<String> = {
        let dutch = """
        de het een en of maar want dus dan als om te in op aan bij voor van met naar uit over onder tussen door tot sinds zonder tegen \
        ik je jij u hij zij ze we wij jullie mij me mijn mijne jouw jou uw zijn haar hun hen ons onze die dat dit deze er hier daar \
        wat wie waar wanneer waarom hoe welke welk hoeveel hoelang waarover waarin waarvan wat's \
        is ben bent zijn was waren wordt worden werd geweest heb hebt heeft hebben had hadden kan kun kunt kunnen kon \
        zal zul zult zullen zou zouden wil wilt willen wou moet moeten mag mogen doe doet doen deed gedaan ga gaat gaan ging \
        staat staan stond stonden stuk zeg zegt zeggen zei vertel vertellen geef geven laat laten zien toon tonen weet weten \
        zoek zoeken zocht vind vinden vond lees lezen las gelezen kijk kijken keek check checken schreef schrijf geschreven \
        samenvatting samenvatten vat samen uitleg leg uit noem noemde noemen afgesproken besproken gezegd gevraagd \
        niet geen nog al ook wel even eens graag alsjeblieft aub please iets niets alles allemaal veel weinig meer minder \
        heel erg zo nu dan toen ooit altijd nooit soms vaak eigenlijk precies ongeveer gewoon echt alleen ander andere \
        nook hoi hallo hey ok oke goed dank bedankt \
        notitie notities note notes aantekening aantekeningen memo memos mail mails email emails e-mail mailtje inbox bericht berichten \
        bestand bestanden document documenten file files pdf map mappen agenda kalender afspraak afspraken herinnering herinneringen \
        taak taken todo github notion issue issues pr prs repo internet web online google browser tab tabs tabblad pagina site website \
        scherm venster app apps klembord contact contacten bron bronnen \
        chat chats chatje chatjes gesprek gesprekken appje appjes geappt appte imessage imessages sms sms'je sms'jes \
        whatsapp whats-app slack teams discord telegram signal \
        ongelezen gelezen beantwoord beantwoorden antwoord antwoorden reageren reactie \
        open openstaan openstaand openstaande onbeantwoord onbeantwoorde wacht wachten wachtend wachtende status \
        vandaag morgen gisteren overmorgen eergisteren straks vanavond vanochtend vanmiddag vannacht week weken maand maanden jaar \
        maandag dinsdag woensdag donderdag vrijdag zaterdag zondag weekend ochtend middag avond nacht uur tijd keer \
        laatste laatst nieuwste nieuw nieuwe recent recente vorige volgende eerste eerder later
        """
        let english = """
        the a an and or but so then if to in on at by for of with from about into over under between through until since \
        without against i you he she it we they me my mine your yours his her its our their them us this that these those there here \
        what who where when why how which whose whom \
        am is are was were be been being have has had do does did done can could will would shall should may might must \
        get got go goes going went tell show give let see find found search look looking read check know say said says wrote write \
        summary summarize summarise explain mention mentioned \
        not no yet also just please something anything nothing everything all some any more less very really only other \
        notes note memo mail mails email emails message messages file files document documents folder calendar event events reminder reminders \
        task tasks todo issue issues repo internet web online browser tab tabs page site website screen window clipboard contact contacts source sources \
        chat chats conversation conversations thread threads text texts texted whatsapp imessage sms slack teams discord telegram signal \
        unread read replied reply answer open pending unanswered waiting awaiting outstanding \
        today tomorrow yesterday tonight morning afternoon evening night week weeks month months year \
        monday tuesday wednesday thursday friday saturday sunday weekend hour time last latest newest new recent previous next first earlier
        """
        let german = """
        der die das ein eine einen einem einer und oder aber denn also dann wenn zu im am um bei für von mit nach aus über unter zwischen durch bis seit ohne gegen \
        ich du er sie es wir ihr mich mir mein meine meinen dein deine sein seine ihre unser unsere dies diese dieser hier dort \
        was wer wo wann warum wie welche welcher welches \
        ist bin bist sind war waren wird werden wurde habe hast hat haben hatte kann kannst können konnte soll sollte will willst möchte muss müssen \
        steht stehen stand sag sagt zeig zeige gib such suche suchen finde finden lies lesen schau schauen weiß wissen schrieb schreib \
        zusammenfassung zusammenfassen erkläre erklär \
        nicht kein keine noch schon auch bitte etwas nichts alles viel mehr weniger sehr nur andere \
        notiz notizen dokument dokumente datei dateien ordner kalender termin termine erinnerung erinnerungen aufgabe aufgaben \
        nachricht nachrichten bildschirm quelle quellen ungelesen gelesen beantwortet antwort offen offene unbeantwortet unbeantwortete \
        heute morgen gestern woche monat jahr montag dienstag mittwoch donnerstag freitag samstag sonntag letzte neueste neu vorige nächste
        """
        return Set((dutch + " " + english + " " + german).split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
    }()

    static func terms(in text: String, history: [ChatTurn] = []) -> Terms {
        var terms = extract(text)
        // A short follow-up ("en het budget?", "what else does it say?") is about the same thing as the question before.
        if let previous = history.last(where: \.fromUser)?.text, terms.words.count < 2, terms.phrases.isEmpty, isFollowUp(text) {
            let before = extract(previous)
            if !before.isEmpty {
                terms.words += before.words.filter { !terms.words.contains($0) }
                terms.phrases += before.phrases.filter { !terms.phrases.contains($0) }
                terms.names += before.names.filter { !terms.names.contains($0) }
                terms.inherited = true
            }
        }
        terms.words = Array(terms.words.prefix(8))
        return terms
    }

    private static func extract(_ text: String) -> Terms {
        var terms = Terms()
        // "…", „…", “…” or ‘…’: a phrase to keep whole (not the apostrophe of "m'n" or "Jan's").
        if let regex = try? NSRegularExpression(pattern: #"["“„‘]([^"“”„‘’]{2,60})["”’]"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let phrase = text[range].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !phrase.isEmpty, !terms.phrases.contains(phrase) { terms.phrases.append(phrase) }
            }
        }
        let tokens = text.split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "." || $0 == "@") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-.")) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var words: [(word: String, index: Int)] = []
        // The name of a source says where to look, not what to look for ("heb ik chats openstaan in WhatsApp?").
        let sourceNames = Set(SourceCatalog.all.map { $0.title.lowercased() }.filter { !$0.contains(" ") })
        for (index, token) in tokens.enumerated() {
            let lower = token.lowercased()
            guard seen.insert(lower).inserted, !stopwords.contains(lower), !sourceNames.contains(lower), !isDateOrTime(lower) else { continue }
            let hasDigit = lower.contains { $0.isNumber }
            let hasLetter = lower.contains { $0.isLetter }
            // A bare number only counts from four digits (a year, an invoice number), not the "14" of "14:30".
            guard hasLetter ? (lower.count >= 3 || hasDigit) : (hasDigit && lower.count >= 4) else { continue }
            words.append((lower, index))
            // A capital in the middle of a sentence is most likely a name ("Lisa", "Apollo"); the first word may just start it.
            if let first = token.first, first.isUppercase, index > 0 || token.count > 1 && token.dropFirst().contains(where: \.isUppercase) {
                terms.names.append(token)
            }
        }
        // Longer words are usually more specific; names go first among equals.
        let names = Set(terms.names.map { $0.lowercased() })
        terms.words = words.sorted { a, b in
            let (na, nb) = (names.contains(a.word), names.contains(b.word))
            if na != nb { return na }
            return a.word.count != b.word.count ? a.word.count > b.word.count : a.index < b.index
        }.map(\.word)
        return terms
    }

    private static func isDateOrTime(_ word: String) -> Bool {
        word.range(of: #"^(\d{1,2}[:.]\d{2}|\d{1,2}(u|h|uur|am|pm)|\d{4}-\d{2}-\d{2}|\d{1,2}[-/]\d{1,2}([-/]\d{2,4})?|\d{1,2}(e|ste|de|st|nd|rd|th))$"#,
                   options: .regularExpression) != nil
    }

    private static func isFollowUp(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.split(separator: " ").count <= 6 { return true }
        return lower.range(of: #"^(en|and|und|ook|also|wat nog|what else|meer|more|verder|further)\b|\b(die|dat|daar\w*|erin|ervan|erover|hem|haar|it|that|those|them|there|darin|davon)\b"#,
                           options: .regularExpression) != nil
    }

    // MARK: Which sources to search

    /// The question looks something up (as opposed to small talk or a pure command like "pauzeer de muziek").
    static func isLookup(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.contains("?") { return true }
        return lower.range(of: #"^(nook,? )?(wat|wie|waar|wanneer|waarom|hoe|welke?|hoeveel|heb|hebben|is|zijn|was|staat|stond|weet|ken|kun|kan|zoek|vind|lees|toon|laat|geef|vertel|vat|check|kijk|what|who|where|when|why|how|which|do|does|did|is|are|was|have|has|find|search|look|read|show|tell|give|summari[sz]e|check|was|wer|wo|wann|warum|wie|welche|habe|hast|suche|finde|lies|zeig|gib|erzähl|fasse)\b"#,
                           options: .regularExpression) != nil
            || lower.range(of: #"\b(samenvatting|samenvatten|vat .{0,40}samen|summary|summari[sz]e|zusammenfass\w*|wat (staat|stond|weet|zei|schreef)|what (does|did|do) .{0,30}(say|said|write|wrote))\b"#,
                           options: .regularExpression) != nil
    }

    /// The question wants the content of something ("lees mijn laatste notitie", "vat de mail samen"), not just a list.
    static func wantsContent(_ text: String) -> Bool {
        text.range(of: #"\b(lees|lezen|voor ?lezen|samenvat\w*|vat .{0,40}samen|samenvatting|inhoud|wat staat er|wat stond er|read|summari[sz]e|summary|content|what does .{0,30}say|lies|lesen|zusammenfass\w*|inhalt)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The tool to search a source with, and the input for these terms. Known search tools first; any other read tool
    /// with a single text field for a query (MCP servers, custom sources) works too.
    static func search(source: String, terms: Terms, question: String, available: [Prefetch.Available]) -> Prefetch.Call? {
        guard !terms.isEmpty else { return nil }
        let candidates = available.filter { $0.source == source }
        let known = candidates.first { searchTools[$0.name] != nil && isSearch($0) }
        guard let tool = known ?? candidates.first(where: isSearch) else { return nil }
        let field = tool.query ?? "query"
        let text: String
        switch tool.name {
        case "search_web":
            // A web search engine understands the question itself better than a bag of words.
            text = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        case "search_contacts":
            guard let name = terms.names.first else { return nil }
            text = name
        case "search_reminders", "notion_search":
            text = terms.query(limit: 1)
        case "search_notes", "search_mail", "search_messages", "search_whatsapp", "search_bear", "search_things":
            // These tools match any of the words and rank by how many match.
            text = terms.query(limit: 6)
        default:
            text = terms.query(limit: 3)
        }
        guard !text.isEmpty else { return nil }
        return Prefetch.Call(tool: tool.name, input: [field: text])
    }

    /// Sources a question that names none is searched in: everything Nook can search on the Mac and in connected
    /// services. Not the web (the user's own data first), not contacts (only for a name) and not the screen.
    static func searchable(_ available: [Prefetch.Available], active: Set<String>) -> Set<String> {
        let skip: Set<String> = [SourceCatalog.web, "contacts", SourceCatalog.screen, "clipboard", "browser", "terminal"]
        return Set(available.filter { active.contains($0.source) && !skip.contains($0.source) && isSearch($0) }.map(\.source))
    }

    /// A read tool that takes a search text and needs nothing else.
    static func isSearch(_ tool: Prefetch.Available) -> Bool {
        guard let field = tool.query else { return false }
        return tool.required.allSatisfy { $0 == field }
    }

    /// The sources to look in for this question. The router's choice, plus, for a follow-up, what the question before
    /// was about; a lookup that names no source of its own is searched everywhere Nook can search; a name also goes
    /// to Contacts.
    /// `named` are the sources the question names itself ("in WhatsApp"): then the user said where to look, and Nook never
    /// falls back to searching everywhere, also not when that source cannot be read right now.
    static func sources(question: String, intent: ChatIntent, terms: Terms, relevant: Set<String>, previous: Set<String> = [],
                        named: Set<String> = [], available: [Prefetch.Available], active: Set<String>) -> Set<String> {
        var sources = relevant
        if terms.inherited { sources.formUnion(previous) }
        let own = sources.subtracting(Prefetch.inContext)
        if own.isEmpty, named.isEmpty, intent.kinds.isEmpty, !terms.isEmpty, isLookup(question) {
            sources.formUnion(searchable(available, active: active))
        }
        if !terms.names.isEmpty, active.contains("contacts"), (isLookup(question) && named.isEmpty) || own.contains("contacts") || named.contains("contacts") {
            sources.insert("contacts")
        }
        return sources
    }

    /// The lookups for these sources: a search with the terms where the source can search, otherwise (or when the
    /// question asks for the newest or unread items) the source's own overview, as `Prefetch` picks it.
    static func lookups(question: String, terms: Terms, sources: Set<String>, available: [Prefetch.Available], limit: Int = 6) -> [Prefetch.Call] {
        let order = SourceCatalog.all.map(\.id)
        var searches: [Prefetch.Call] = []
        var overviews: [Prefetch.Call] = []
        for source in sources.subtracting(Prefetch.inContext).sorted(by: { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }) {
            let search = Self.search(source: source, terms: terms, question: question, available: available)
            if let search { searches.append(search) }
            if search == nil || Prefetch.prefersListing(source, question) {
                overviews += Prefetch.calls(for: question, relevant: [source], available: available, limit: 1)
            }
        }
        // Searches first: they answer the question; overviews only add background.
        return Array((searches + overviews).prefix(limit))
    }

    /// Search tools Nook knows, with the tool that opens one of their hits (nil: the hit is complete already).
    static let searchTools: [String: String?] = [
        "search_notes": "read_note", "list_notes": "read_note",
        "search_mail": "read_mail", "inbox_mail": nil,
        "search_files": "read_file",
        "notion_search": "notion_read_page",
        "github_search": "github_issue_details",
        "search_web": "read_webpage",
        "search_messages": "read_messages", "search_whatsapp": "read_whatsapp",
        "messages_open_chats": "read_messages", "whatsapp_open_chats": "read_whatsapp",
        "search_bear": "read_bear", "search_things": nil,
        "search_reminders": nil, "search_contacts": nil
    ]

    /// Read tools that belong with these tools, so a model that is offered a search can also open what it finds.
    static func companions(of tools: [String]) -> [String] {
        var result: [String] = []
        for tool in tools {
            if let reader = searchTools[tool] ?? nil, !tools.contains(reader), !result.contains(reader) { result.append(reader) }
        }
        return result
    }

    // MARK: Hits

    /// One thing a search found, and how to open it in full.
    struct Hit {
        var tool: String
        var title: String
        /// What the search showed of it (start of the text, a path, a snippet).
        var text: String
        var read: String?
        var input: [String: Any] = [:]
        /// The search already showed all of it: no need to open it.
        var complete = false
        /// Position in the search result (the source's own ranking).
        var position = 0
    }

    /// The hits in one search result, in the order the source returned them.
    static func hits(in output: String, tool: String) -> [Hit] {
        var hits: [Hit]
        switch tool {
        case "search_notes":
            hits = headed(output).map { section in
                let id = bracket("id", in: section.heading)
                // The search shows at most the first 800 characters of a note.
                return Hit(tool: tool, title: plainTitle(section.heading), text: section.body, read: "read_note",
                           input: ["identifier": id ?? plainTitle(section.heading)], complete: section.body.count < 750)
            }
        case "search_bear":
            hits = headed(output).map { section in
                Hit(tool: tool, title: plainTitle(section.heading), text: section.body, read: "read_bear",
                    input: ["id": bracket("id", in: section.heading) ?? ""], complete: section.body.count < 750)
            }.filter { !(($0.input["id"] as? String) ?? "").isEmpty }
        case "search_messages", "search_whatsapp", "messages_open_chats", "whatsapp_open_chats":
            // One hit per conversation; reading it shows the passages around the matches.
            hits = headed(output).compactMap { section in
                guard let chat = bracket("chat", in: section.heading) else { return nil }
                return Hit(tool: tool, title: plainTitle(section.heading), text: section.body,
                           read: tool.contains("whatsapp") ? "read_whatsapp" : "read_messages", input: ["chat": chat])
            }
        case "list_notes":
            hits = lines(output, prefix: "- ").compactMap { line in
                guard let id = bracket("id", in: line) else { return nil }
                let title = line.components(separatedBy: " — ").first.map { plainTitle($0) } ?? plainTitle(line)
                return Hit(tool: tool, title: title, text: "", read: "read_note", input: ["identifier": id])
            }
        case "search_mail":
            hits = headed(output).map { section in
                let id = bracket("id", in: section.heading)
                return Hit(tool: tool, title: plainTitle(section.heading), text: section.heading + "\n" + section.body,
                           read: id == nil ? nil : "read_mail", input: id.map { ["id": $0] } ?? [:], complete: section.body.count < 650)
            }
        case "search_files":
            hits = output.split(separator: "\n").map(String.init).filter { $0.hasPrefix("~/") || $0.hasPrefix("/") }.map { path in
                Hit(tool: tool, title: (path as NSString).lastPathComponent, text: path,
                    read: readable(path) ? "read_file" : nil, input: ["path": path])
            }
        case "notion_search":
            hits = lines(output, prefix: "- ").compactMap { line in
                guard let match = line.range(of: #"\(id [0-9a-fA-F-]{32,36}\)"#, options: .regularExpression) else { return nil }
                let id = String(line[match].dropFirst(4).dropLast())
                let title = String(line[line.index(line.startIndex, offsetBy: 2)..<match.lowerBound]).trimmingCharacters(in: .whitespaces)
                return Hit(tool: tool, title: title, text: line, read: "notion_read_page", input: ["page": id])
            }
        case "github_search":
            hits = lines(output, prefix: "- ").compactMap { line in
                guard let match = line.range(of: #"^- [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+#\d+"#, options: .regularExpression) else { return nil }
                let ref = line[match].dropFirst(2)
                let parts = ref.split(separator: "#")
                guard parts.count == 2, let number = Int(parts[1]) else { return nil }
                let title = line.range(of: #"'.*'"#, options: .regularExpression).map { String(line[$0].dropFirst().dropLast()) } ?? String(ref)
                return Hit(tool: tool, title: title, text: line, read: "github_issue_details", input: ["repo": String(parts[0]), "number": number])
            }
        case "search_web":
            hits = headed(output).compactMap { section in
                let bodyLines = section.body.split(separator: "\n", maxSplits: 1).map(String.init)
                guard let url = bodyLines.first?.trimmingCharacters(in: .whitespaces), url.hasPrefix("https://") else { return nil }
                return Hit(tool: tool, title: plainTitle(section.heading), text: bodyLines.count > 1 ? bodyLines[1] : "",
                           read: "read_webpage", input: ["url": url])
            }
        default:
            hits = []
        }
        for index in hits.indices { hits[index].position = index }
        return hits
    }

    /// How well a hit matches: a word in the title counts three times, in the text once; a quoted phrase twice as much.
    static func score(title: String, text: String, terms: Terms) -> Int {
        let (title, text) = (fold(title), fold(text))
        var score = 0
        for phrase in terms.phrases {
            let folded = fold(phrase)
            if title.contains(folded) { score += 6 } else if text.contains(folded) { score += 2 }
        }
        for word in terms.words {
            let folded = fold(word)
            if title.contains(folded) { score += 3 } else if text.contains(folded) { score += 1 }
        }
        return score
    }

    /// The hits worth opening, best first, across all sources: only hits that match the terms (or, without terms, the
    /// newest item when the question asks for the content), at most `perSource` per source and `limit` in total.
    static func toOpen(_ results: [(tool: String, output: String)], terms: Terms, wantsContent: Bool,
                       available: Set<String>, limit: Int, perSource: Int = 2, openers: [String: Opener] = [:]) -> [Hit] {
        guard limit > 0 else { return [] }
        var candidates: [(hit: Hit, score: Int, order: Int)] = []
        for (order, result) in results.enumerated() {
            var found = hits(in: result.output, tool: result.tool)
            if found.isEmpty, let opener = openers[result.tool] { found = genericHits(in: result.output, tool: result.tool, opener: opener) }
            for var hit in found {
                if hit.read == "read_messages" || hit.read == "read_whatsapp", !terms.isEmpty { hit.input["query"] = terms.query(limit: 6) }
                guard let read = hit.read, available.contains(read), !hit.complete else { continue }
                if terms.isEmpty {
                    if wantsContent, hit.position == 0 { candidates.append((hit, 1, order)) }
                    continue
                }
                let score = Self.score(title: hit.title, text: hit.text, terms: terms)
                if score > 0 { candidates.append((hit, score, order)) }
            }
        }
        candidates.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.hit.position != b.hit.position { return a.hit.position < b.hit.position }
            return a.order < b.order
        }
        var picked: [Hit] = []
        var perTool: [String: Int] = [:]
        for candidate in candidates where picked.count < limit {
            let tool = candidate.hit.read ?? candidate.hit.tool
            guard perTool[tool, default: 0] < perSource else { continue }
            perTool[tool, default: 0] += 1
            picked.append(candidate.hit)
        }
        return picked
    }

    /// Keeps the best `keep` of a tool's raw results, ranked by the terms (stable: equal scores keep the source's order).
    /// `chunks` are the results as the tool collected them; `text` gives the part to match the terms against.
    static func best<T>(_ chunks: [T], terms: Terms, keep: Int, title: (T) -> String, text: (T) -> String) -> [T] {
        guard !terms.isEmpty else { return Array(chunks.prefix(keep)) }
        let scored = chunks.enumerated().map { (index: $0.offset, chunk: $0.element, score: score(title: title($0.element), text: text($0.element), terms: terms)) }
        let matching = scored.filter { $0.score > 0 }
        let pool = matching.isEmpty ? scored : matching
        return pool.sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }.prefix(keep).map(\.chunk)
    }

    /// A query split into the words it matches on: the AppleScript searches of Notes and Mail match any of them.
    static func words(of query: String) -> [String] {
        let quoted = extract(query)
        let words = quoted.isEmpty
            ? query.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 }
            : quoted.all
        return Array(words.prefix(6))
    }

    // MARK: Any search with a read tool (MCP servers)

    /// How to open a hit of a search that Nook does not know: the source's read tool and the one field it needs.
    struct Opener: Equatable {
        var tool: String
        var field: String
    }

    /// For every search of a source Nook does not know, the tool of the same source that opens one item: a read tool
    /// named like get/read/fetch/show/open/view/details that needs exactly one field.
    static func openers(_ available: [Prefetch.Available]) -> [String: Opener] {
        var result: [String: Opener] = [:]
        for search in available where searchTools[search.name] == nil && isSearch(search) {
            let reader = available.first { tool in
                tool.name != search.name && tool.source == search.source && tool.required.count == 1 && tool.query == nil
                    && tool.name.range(of: #"(get|read|fetch|retrieve|show|open|view|detail|lookup|page|document|item)"#,
                                       options: [.regularExpression, .caseInsensitive]) != nil
            }
            if let reader, let field = reader.required.first { result[search.name] = Opener(tool: reader.name, field: field) }
        }
        return result
    }

    /// Hits in the output of an unknown search: the objects of a JSON answer (with an id, key or url and a title or
    /// name), or else every line that names an id ("id: ABC-12", "(id 123)").
    static func genericHits(in output: String, tool: String, opener: Opener) -> [Hit] {
        let idKeys = [opener.field, "id", "key", "identifier", "uuid", "slug", "number", "url", "uri", "path"]
        let titleKeys = ["title", "name", "subject", "summary", "displayName", "label", "text"]
        var hits: [Hit] = []
        if let objects = jsonObjects(in: output) {
            for object in objects {
                guard let id = idKeys.lazy.compactMap({ value(object[$0]) }).first else { continue }
                let title = titleKeys.lazy.compactMap { value(object[$0]) }.first ?? id
                let text = object.compactMap { key, raw in value(raw).map { "\(key): \($0)" } }.sorted().joined(separator: "\n")
                hits.append(Hit(tool: tool, title: title, text: text, read: opener.tool, input: [opener.field: id], position: hits.count))
            }
            return hits
        }
        let pattern = try? NSRegularExpression(pattern: #"(?i)\b(?:id|key)\s*[:=]?\s*["'`]?([A-Za-z0-9][A-Za-z0-9_\-:./]{1,80})"#)
        for line in output.components(separatedBy: "\n") where !line.hasPrefix("Sources in this result") && !line.hasPrefix("[") {
            guard let pattern, let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            let id = String(line[range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.,;)"))
            hits.append(Hit(tool: tool, title: line.trimmingCharacters(in: CharacterSet(charactersIn: "-*• ")), text: line,
                            read: opener.tool, input: [opener.field: id], position: hits.count))
        }
        return hits
    }

    private static func value(_ raw: Any?) -> String? {
        if let text = raw as? String, !text.isEmpty { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    /// The list of objects in a JSON answer: the top-level array, or the first array of objects inside the top-level
    /// object (results, items, data, issues…), one level deep.
    private static func jsonObjects(in output: String) -> [[String: Any]]? {
        guard let start = output.firstIndex(where: { $0 == "[" || $0 == "{" }) else { return nil }
        let closing: Character = output[start] == "[" ? "]" : "}"
        guard let end = output.lastIndex(of: closing), end > start,
              let data = String(output[start...end]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let list = json as? [[String: Any]] { return list }
        guard let object = json as? [String: Any] else { return nil }
        for key in object.keys.sorted() {
            if let list = object[key] as? [[String: Any]], !list.isEmpty { return list }
            if let inner = object[key] as? [String: Any] {
                for innerKey in inner.keys.sorted() {
                    if let list = inner[innerKey] as? [[String: Any]], !list.isEmpty { return list }
                }
            }
        }
        return [object]
    }

    // MARK: Only what is about the question

    /// Search tools whose results Nook can split into separate items.
    private static let itemized: Set<String> = [
        "search_notes", "search_mail", "search_bear", "search_messages", "search_whatsapp", "search_files",
        "github_search", "notion_search", "search_things", "search_reminders"
    ]

    /// A search result without the items that have nothing to do with the question, so the model never answers from
    /// an unrelated note or mail that happened to match one common word. When nothing is about the question, says so.
    static func relevantOnly(_ output: String, tool: String, terms: Terms) -> String {
        guard !terms.isEmpty, itemized.contains(tool) else { return output }
        // Notes, mail and chats are sections under a heading (their text may hold lists); the others are one line each.
        let headed: Set<String> = ["search_notes", "search_mail", "search_bear", "search_messages", "search_whatsapp"]
        let starts: (String) -> Bool = headed.contains(tool)
            ? { $0.hasPrefix("### ") }
            : { $0.hasPrefix("- ") || $0.hasPrefix("~/") || $0.hasPrefix("/") }
        var head: [String] = []
        var items: [[String]] = []
        var tail: [String] = []
        for line in output.components(separatedBy: "\n") {
            if !tail.isEmpty || line.hasPrefix("Sources in this result") {
                tail.append(line)
            } else if starts(line) {
                items.append([line])
            } else if items.isEmpty {
                head.append(line)
            } else {
                items[items.count - 1].append(line)
            }
        }
        guard !items.isEmpty else { return output }
        let kept = items.filter { item in score(title: item[0], text: item.dropFirst().joined(separator: "\n"), terms: terms) > 0 }
        if kept.isEmpty { return "(\(items.count) results, none of them about \"\(terms.query(limit: 6))\".)" }
        guard kept.count < items.count else { return output }
        let note = "(\(items.count - kept.count) results that are not about \"\(terms.query(limit: 6))\" left out.)"
        return (head + kept.flatMap { $0 } + [note] + tail).joined(separator: "\n")
    }

    /// The parts of a long text (an app's window, a page) that are about the question: every line that matches, with
    /// two lines before and after, in order. Without a match, the start of the text.
    static func focus(_ text: String, terms: Terms, limit: Int) -> String {
        guard !terms.isEmpty, text.count > limit / 2 else { return String(text.prefix(limit)) }
        // The numbered sources at the end stay, so the answer can still cite them.
        var body = text
        var sources = ""
        if let range = text.range(of: "\n\nSources in this result") {
            body = String(text[..<range.lowerBound])
            sources = String(text[range.lowerBound...])
        }
        let lines = body.components(separatedBy: "\n")
        let matches = lines.indices.filter { score(title: "", text: lines[$0], terms: terms) > 0 }
        guard !matches.isEmpty else { return String(body.prefix(max(0, limit - sources.count))) + sources }
        // The first line names the document.
        var keep: Set<Int> = [0]
        for index in matches { keep.formUnion(max(0, index - 2)...min(lines.count - 1, index + 2)) }
        var parts: [String] = []
        var previous: Int?
        var size = 0
        for index in keep.sorted() {
            if let previous, index > previous + 1 { parts.append("…") }
            parts.append(lines[index])
            size += lines[index].count + 1
            previous = index
            if size > limit - sources.count { break }
        }
        return "(The parts about \"\(terms.query(limit: 6))\":)\n" + parts.joined(separator: "\n") + sources
    }

    // MARK: Files worth showing

    /// Build output and installed packages are never what someone asks about ("dist/assets/index-BRcVVYD8.js").
    static func isBuildOutput(_ path: String) -> Bool {
        let parts = ["/node_modules/", "/dist/", "/build/", "/.build/", "/DerivedData/", "/Pods/", "/.git/", "/vendor/",
                     "/.next/", "/.nuxt/", "/target/", "/coverage/", "/.cache/", "/__pycache__/", "/.venv/", "/venv/"]
        return parts.contains { path.contains($0) } || path.hasSuffix(".map") || path.hasSuffix(".min.js")
    }

    /// Source code, which matches nearly every word but is rarely the answer to a question about the user's own life.
    static func isSourceCode(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "go", "rs", "java", "kt", "c", "cc", "cpp", "h", "hpp", "m", "mm",
                "rb", "php", "cs", "css", "scss", "less", "vue", "svelte", "sh", "lock", "plist", "xcconfig", "pbxproj", "gradle"].contains(ext)
    }

    /// Search hits in the order worth showing: documents first, then source code; build output left out. Keeps the
    /// order of Spotlight within each group. `codeFirst` when the question is about code.
    static func rankFiles(_ paths: [String], codeFirst: Bool = false) -> [String] {
        let kept = paths.filter { !isBuildOutput($0) }
        let code = kept.filter(isSourceCode)
        let documents = kept.filter { !isSourceCode($0) }
        return codeFirst ? code + documents : documents + code
    }

    // MARK: Parsing helpers

    private static func headed(_ output: String) -> [(heading: String, body: String)] {
        var sections: [(heading: String, body: String)] = []
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("### ") {
                sections.append((String(line.dropFirst(4)), ""))
            } else if !sections.isEmpty {
                // The ledger appends the numbered source list; it is not part of the last hit.
                if line.hasPrefix("Sources in this result") { break }
                sections[sections.count - 1].body += (sections[sections.count - 1].body.isEmpty ? "" : "\n") + line
            }
        }
        return sections.map { ($0.heading, $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func lines(_ output: String, prefix: String) -> [String] {
        output.components(separatedBy: "\n").filter { $0.hasPrefix(prefix) }
    }

    /// The value in "[key: value]" within a line.
    private static func bracket(_ key: String, in line: String) -> String? {
        guard let range = line.range(of: "[\(key): ") else { return nil }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "]") else { return nil }
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// A heading without its trailing metadata: "Verbouwing [map: Huis] | 2026-10-01 [id: x]" → "Verbouwing".
    private static func plainTitle(_ heading: String) -> String {
        var title = heading.hasPrefix("- ") ? String(heading.dropFirst(2)) : heading
        for marker in [" [map: ", " [id: ", " | ", " (", " — "] {
            if let range = title.range(of: marker) { title = String(title[..<range.lowerBound]) }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private static func readable(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return ["txt", "md", "markdown", "pdf", "doc", "docx", "rtf", "rtfd", "odt", "pages", "html", "htm", "csv", "json", "xml", "yaml", "yml", "tex", "org", "log"].contains(ext)
    }

    /// Lowercase without accents, so "café" matches "cafe" and "Überweisung" matches "uberweisung".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
