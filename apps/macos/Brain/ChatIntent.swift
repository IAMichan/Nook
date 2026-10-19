import Foundation

/// What one chat message asks for, recognized on the Mac itself before any model runs (Dutch, English and German).
///
/// A small local model picks badly from a long tool list and often answers about the context instead of the question.
/// The intent tells the brain which tools belong to this request (they are always offered first), whether the user
/// wants Nook to *do* something, and which single action to fill in when the model proposed nothing.
struct ChatIntent: Equatable {
    enum Kind: String, CaseIterable {
        case reminder, event, availability, note, todo, mailWrite, mailRead, contacts, music, volume, openApp, shortcut
        case chart, screen, browser, files, github, notion, clipboard, web, chats, chatWrite, memory, control
    }

    /// Recognized kinds, strongest first.
    var kinds: [Kind] = []
    /// The user asks Nook to do something (make, send, plan, open…), not only a question.
    var wantsAction = false
    /// A greeting or thanks: no sources or tools needed.
    var isSmallTalk = false

    var isEmpty: Bool { kinds.isEmpty }

    /// Tools that belong to this request, most important first. Names may include tools that are not connected.
    var tools: [String] {
        var seen = Set<String>()
        return kinds.flatMap { Self.toolsByKind[$0] ?? [] }.filter { seen.insert($0).inserted }
    }

    /// The one action this request is about, when it clearly asks for one.
    var primaryAction: String? {
        guard wantsAction else { return nil }
        for kind in kinds {
            // "Vat mijn notitie over X samen" reads a note; it only makes one when asked to ("zet het in een notitie").
            if kind == .note, readsNotes { continue }
            if kind == .event, moves { return "update_event" }
            // "Wat weet je over mij?" asks, it does not store anything.
            if kind == .memory { if forgets { return "forget" }; if recalls { continue } }
            if let action = Self.actionByKind[kind] { return action }
        }
        return nil
    }

    /// "Move my meeting", "verplaats de afspraak": an existing event changes.
    private(set) var moves = false
    /// "Vergeet dat…": something remembered goes.
    private(set) var forgets = false
    /// "Wat weet je over mij?": a question about what Nook remembers.
    private(set) var recalls = false
    /// "Wat staat er in mijn notitie over…", "vat mijn notities samen": notes are where the answer is, not what to make.
    private(set) var readsNotes = false

    // MARK: Recognition

    static func detect(_ raw: String) -> ChatIntent {
        let text = fixingSendTypo(raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        var intent = ChatIntent()
        guard !text.isEmpty else { return intent }

        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        var kinds: [Kind] = []
        // "App Lisa dat ik later ben", "stuur via WhatsApp…", "WhatsApp Jan": a chat message, not a mail.
        let writesChat = has(#"^(app|whatsapp)\s+\p{L}+(\s+\p{L}+)?\s*(:|\b(dat|om|of|that|to|if|dass|ob)\b)"#)
            || has(#"(stuur|verstuur|beantwoord|antwoord|schrijf|send|reply|write|schick|sende|schreib)\b[^.?!]{0,60}\b(whats-?app|appje|app-?bericht)"#)
            || has(#"\b(via|over|per|on|through|in|über|bei) whats-?app\b"#) && has(#"\b(stuur|verstuur|zeg|laat \p{L}+ weten|vraag|send|tell|ask|let \p{L}+ know|schick|sag|frag)"#)
            || has(#"\b(app|whatsapp) (hem|haar|ze|him|her|them|ihm|ihr)\b"#)
        let writesMail = !writesChat && (has(#"(schrijf|stuur|verstuur|beantwoord|antwoord|maak|write|send|draft|reply|answer|schreib|sende|beantworte)\b[^.?!]{0,40}\b(e-?mail|mail|mailtje|bericht)"#)
            || has(#"\b(e-?mail|mail)(tje)? (naar|aan|to|an)\b"#) || has(#"^(mail|e-?mail) \p{L}+"#) || has(#"\b(reply to|antwoord op|reageer op)\b"#))
        // Remembering something lasting is memory; "onthoud dat ik morgen moet bellen" is a task and stays a reminder.
        let remembers = MemoryRequest.asksToRemember(text)
        intent.forgets = MemoryRequest.asksToForget(text)
        intent.recalls = MemoryRequest.asksWhatIsKnown(text)
        if remembers || intent.forgets || intent.recalls { kinds.append(.memory) }
        if has(#"herinner|herinnering|\breminder|remind me|erinner|vergeet (ik )?niet|niet vergeten|don'?t forget"#) { kinds.append(.reminder) }
        if has(#"beschikbaar|\bvrij\b|\bbezet\b|available|availability|\bfree (on|at|this|next|tomorrow|today)|am i free|verfügbar|\bfrei\b|tijd voor een|time for a"#) { kinds.append(.availability) }
        if has(#"afspra|meeting|vergader|overleg|\bcall\b|inplannen|\bplan\b[^.?!]{0,30}\bin\b|agenda|calendar|kalender|\btermin|\bevent|evenement|verplaats|reschedule|\bmove (my|the)\b|verschieb|lunch met|diner met|lunch with|dinner with"#) { kinds.append(.event) }
        if writesMail { kinds.append(.mailWrite) }
        if writesChat { kinds.append(.chatWrite) }
        if has(#"notitie|noteer|\bnotes?\b|aantekening|\bmemo|notiz|schrijf (dit|het|dat) op|write (this|it|that) down"#) { kinds.append(.note) }
        if has(#"\btaak\b|\btaken\b|\btodos?\b|to-do|open punt|actiepunt|nog (te )?doen|moet ik (vandaag|nog)|\btasks?\b|\baufgabe"#) { kinds.append(.todo) }
        if !writesMail, has(#"\bmails?\b|e-?mails?\b|inbox|ongelezen|unread|postvak|\bpost\b"#) { kinds.append(.mailRead) }
        if !writesMail, !writesChat, has(#"whats-?app|imessage|app-?groep|groeps-?app|groeps-?chat|group ?chat|gruppenchat|\bsms|\bchats?\b|\bchatje|\bappjes?\b|ge-?appt|\bappte|\bberichten\b(?!-?app)|\bmessages?\b|\btexts?\b|\btexted|\bnachrichten"#) { kinds.append(.chats) }
        if has(#"telefoonnummer|nummer van|mailadres|e-?mailadres|adres van|\bcontact|phone number|email address|telefonnummer"#) { kinds.append(.contacts) }
        if has(#"muziek|liedje|\bnummer\b(?! van)|\bspeel|afspelen|spotify|pauzeer|\bmusic\b|\bsong|\bplay\b|\bmusik"#) { kinds.append(.music) }
        if has(#"volume|\bgeluid|harder|zachter|louder|quieter|lautstärke|leiser|lauter"#) { kinds.append(.volume) }
        if has(#"^(open|start|launch|öffne|starte)\s+\S+(\s+\S+)?$|\b(open|start) (de |het |the )?app\b"#) { kinds.append(.openApp) }
        if has(#"shortcut|kurzbefehl|opdracht(en)? (uitvoeren|draaien)"#) { kinds.append(.shortcut) }
        if has(#"grafiek|diagram|\bchart|\bplot\b|visualiseer|visualize|staafdiagram|taartdiagram"#) { kinds.append(.chart) }
        // Doing something in an app by hand: a switch in System Settings, a click, typing into a field.
        if has(#"systeeminstelling|system ?settings|systemeinstellung|réglages système|ajustes del sistema|\bklik|\bclick|\bklick|\bcliqu|\bmuis|\bmouse|\bmaus\b|toetsenbord|keyboard|tastatur|\bdruk op\b|\btyp (in|het|dit|dat)\b|\btype (in|this|it)\b|(instelling|setting|einstellung)\w* (aan|uit|wijzig|verander|aanpass|on|off|change|ändern)|(zet|schakel|turn|switch|schalte?)\b[^.?!]{0,40}\b(aan|uit|on|off|ein|aus)\b[^.?!]{0,30}\b(instelling|setting|einstellung)|\b(night ?shift|dark mode|donkere modus|bluetooth|wi-?fi|niet storen|do not disturb|true tone|screen saver|schermbeveiliging)\b"#) { kinds.append(.control) }
        if has(#"scherm|\bhier\b|\bdit\b|\bdeze (mail|pagina|tekst|tabel|code)|\bthis\b|\bscreen|bildschirm|venster|\bwindow|\bdas hier"#) { kinds.append(.screen) }
        if has(#"browser|tabblad|\btabs?\b|webpagina|\bpagina\b|artikel|website|\bsite\b|article|webseite"#) { kinds.append(.browser) }
        if has(#"bestand|document|\bpdf|\bmap\b|\bfile|folder|\bdatei|\bordner"#) { kinds.append(.files) }
        if has(#"github|pull request|\bprs?\b|\bissues?\b|\brepo|\bmerge"#) { kinds.append(.github) }
        if has(#"notion|\bwiki\b"#) { kinds.append(.notion) }
        if has(#"klembord|clipboard|gekopieerd|\bcopied|zwischenablage|kopiert"#) { kinds.append(.clipboard) }
        if has(#"\bzoek (op|online|op internet)|google|\bweb\b|internet|nieuws|\bweer\b|weerbericht|temperatuur|uitslag|wie won|koers|prijs van|hoeveel kost|wikipedia|openingstijden|search the web|look up online|\bnews\b|weather|who won|price of|wetter|nachrichten"#) { kinds.append(.web) }
        // What the user asks to make wins over what it is about: "a chart of my meetings" is a chart, "mail Lisa about
        // the meeting" is a mail, "remind me of the call" is a reminder.
        intent.kinds = kinds.sorted { (Self.priority.firstIndex(of: $0) ?? 99) < (Self.priority.firstIndex(of: $1) ?? 99) }
        intent.moves = has(#"verplaats|reschedule|\bmove (my|the)\b|verschieb|\bverzet"#)
        let makesNote = has(#"\b(zet|schrijf|sla|bewaar|voeg|put|save|add|write|speicher)[^.?!]{0,40}\b(in|als|naar|to|into|as) (een |mijn |de |a |my )?(nieuwe |new )?(notitie|notities|note|notes)\b|\bals notitie|\bas a note|(maak|create|make|nieuwe|new|erstelle) (een |a |eine )?(nieuwe |new |neue )?(notitie|note|notiz)\b|\bnoteer|schrijf (dit|het|dat) op|write (this|it|that) down|neue notiz"#)
        let readsNote = has(#"(in|uit|from|aus) (mijn|de|m'n|my|the|meine?n?) (\w+ )?(notitie|notities|notes?|notiz\w*)|(lees|zoek|vind|vat|samenvat\w*|wat staat|wat stond|read|search|find|summari[sz]e|what does|lies|such|finde)[^.?!]{0,40}(notitie|notities|notes?|notiz\w*)"#)
        intent.readsNotes = readsNote && !makesNote

        let polite = text
            .replacingOccurrences(of: #"^(nook|hé nook|hey nook|hoi nook|hi nook)[ ,]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(wil je|kun je|kan je|zou je|could you|can you|would you|will you|please|graag|kannst du|könntest du|bitte)\s+"#, with: "", options: .regularExpression)
        let imperative = polite.range(of: #"^(maak|zet|plan|boek|stuur|verstuur|schrijf|noteer|voeg|herinner|onthoud|vergeet|open|start|speel|pauzeer|verplaats|annuleer|mail|app|whatsapp|beantwoord|teken|create|make|add|schedule|book|send|write|remind|remember|forget|note|put|set|move|cancel|draft|reply|play|pause|draw|merk|vergiss|erstelle|schreib|erinnere|plane|trag|sende|öffne|spiele)\b"#, options: .regularExpression) != nil
        let asksPolitely = text.range(of: #"^(nook,? )?(wil je|kun je|kan je|zou je|could you|can you|would you|will you|kannst du|könntest du)\b"#, options: .regularExpression) != nil
        let embedded = has(#"herinner me|remind me|erinnere mich|zet (het|dit|dat|een|'?n)?[^.?!]{0,40} in (mijn|de) (agenda|herinneringen|notities)|vergeet (ik )?niet|\bmaak (een|er een)\b|\bplan (een|het|dat)\b|\bstuur (een|het|dat)\b|\bschrijf (een|het|dat)\b|\bvoeg [^.?!]{0,30} toe\b|\bvoortaan\b|\bfrom now on\b|\bab jetzt\b"#)
        intent.wantsAction = !kinds.isEmpty && (imperative || asksPolitely || embedded)

        let greeting = text.range(of: #"^(hoi|hallo|hey|hi|hello|yo|goedemorgen|goedemiddag|goedenavond|dank( je)?( wel)?|bedankt|thanks|thank you|thx|ok(é|e|ay)?|top|super|prima|cool|nice|haha|moin|guten (morgen|tag|abend)|danke)\b[\s\p{P}\p{So}]*(nook)?[\s\p{P}\p{So}]*$"#, options: .regularExpression) != nil
        intent.isSmallTalk = kinds.isEmpty && greeting
        return intent
    }

    /// A follow-up carries the action of the conversation it continues. "Stuur: Mooi idee" or "Verzend" after a talk about
    /// a WhatsApp message to Arjan names no channel itself; read alone it asks for nothing, and a small model then only
    /// claims it sent the message. Here it becomes that WhatsApp message (or mail) again, so the action is proposed.
    static func detect(_ raw: String, history: [ChatTurn]) -> ChatIntent {
        let raw = fixingSendTypo(raw)
        var intent = detect(raw)
        guard !history.isEmpty, intent.primaryAction == nil else { return intent }
        let recent = Array(history.suffix(6).reversed())
        // "Ja" or "ok" only goes ahead with what Nook just asked ("Wil je het bericht nu verzenden?"), never after a
        // message that was already handled.
        let goAhead = confirms(raw) && recent.first(where: { !$0.fromUser }).map { asks($0.text) } == true
        guard !intent.isSmallTalk || goAhead else { return intent }
        // "Opnieuw", "probeer het nog eens", "try again": the last thing the user asked Nook to do, once more.
        let retry = retries(raw) && !questions(raw)
        // "Nee, naar de appgroep Doosturen", "nee, om 4 uur": the same request with one detail changed, not a new one.
        let correction = corrects(raw) && !questions(raw)
        let carried: Kind?
        if correction {
            // The newest request the user made, with its channel when it was a message.
            carried = recent.lazy.filter(\.fromUser).compactMap { turn -> Kind? in
                if let kind = detect(turn.text).kinds.first(where: { actionByKind[$0] != nil }) { return kind }
                return sends(turn.text) ? channel(of: recent) : nil
            }.first ?? (recent.contains { !$0.fromUser && sends($0.text) } ? channel(of: recent) : nil)
        } else if (sends(raw) && !questions(raw)) || (goAhead && recent.prefix(2).contains { sends($0.text) })
            || (retry && recent.contains { $0.fromUser && sends($0.text) }) {
            carried = channel(of: recent)
        } else if goAhead {
            // "Ja, doe maar" after "maak een herinnering voor morgen": the action the user asked for last.
            carried = recent.first(where: \.fromUser).flatMap { turn in detect(turn.text).kinds.first { actionByKind[$0] != nil } }
        } else if retry {
            // A retry follows a complaint ("hij is niet verzonden") as often as the request itself: the newest request.
            carried = recent.lazy.filter(\.fromUser).compactMap { turn in detect(turn.text).kinds.first { actionByKind[$0] != nil } }.first
        } else {
            carried = nil
        }
        guard let carried else { return intent }
        intent.kinds = [carried] + intent.kinds.filter { $0 != carried && !(carried == .chatWrite && $0 == .chats) }
        intent.wantsAction = true
        intent.isSmallTalk = false
        return intent
    }

    /// The channel the conversation is about: the newest turn that names chats or mail.
    private static func channel(of recent: [ChatTurn]) -> Kind? {
        recent.lazy.compactMap { turn -> Kind? in
            let kinds = detect(turn.text).kinds
            if kinds.contains(.chatWrite) || kinds.contains(.chats) { return .chatWrite }
            if kinds.contains(.mailWrite) || kinds.contains(.mailRead) { return .mailWrite }
            return nil
        }.first
    }

    /// A correction of what was just asked: "nee, naar de appgroep Doosturen", "nee, om 4 uur", "niet naar Jan maar naar
    /// Lisa", "ik bedoel Lisa", "no, to Lisa". A bare "nee", "nee, laat maar" or "nee, op dit moment niet" declines instead.
    static func corrects(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 120 else { return false }
        return text.range(of: #"^(nee|neen|nope|no|nein|non)\b[\s,.!:;-]*(niet|not|nicht|pas)?\s*((naar|aan|to|an|nach|à)\s+(?!be\b)\S|(om|at|um|à)\s+\d)"#, options: .regularExpression) != nil
            || text.range(of: #"^((nee|no|nein)[\s,.!]*)?(ik bedoel(de)?|i meant?|ich meine|je veux dire|quiero decir)\b"#, options: .regularExpression) != nil
            || text.range(of: #"^(niet|not|nicht|pas|no) [^.?!]{1,40}\b(maar|but|sondern|mais|sino)\b"#, options: .regularExpression) != nil
    }

    /// Verbs a short follow-up starts with, so a typo in them ("vestuur", "verstur") is still read as that verb.
    private static let sendVerbs = ["verstuur", "verzend", "stuur", "sende", "schick"]

    /// The text with a mistyped send verb at its start written out ("Vestuur" → "verstuur"): one wrong letter, in words
    /// of five letters or more, and only when one verb is that close.
    static func fixingSendTypo(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let end = trimmed.firstIndex(where: { !$0.isLetter }) ?? trimmed.endIndex
        let word = trimmed[..<end].lowercased()
        // "Stuurt", "verstuurd", "sender" are other words that start with the verb, not typos.
        guard word.count >= 5, !sendVerbs.contains(where: { word.hasPrefix($0) }) else { return raw }
        let close = sendVerbs.filter { Fuzzy.distance(word, $0) == 1 }
        guard close.count == 1, let verb = close.first else { return raw }
        return verb + trimmed[end...]
    }

    /// Sending a message, with or without a channel: "stuur: …", "ik wil een bericht naar Arjan sturen", "verzend".
    static func sends(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return text.range(of: #"^(stuur|verstuur|verzend|send|schick|sende)\b|\b(stuur|stuurt|sturen|verstuur|versturen|verzend|verzenden|send|sending|schicken|senden|sende)\b[^.?!]{0,60}\b(bericht|berichtje|message|nachricht|tekst|text)\b|\b(bericht|berichtje|message|nachricht|tekst|text)\b[^.?!]{0,60}\b(sturen|versturen|verzenden|send|schicken|senden)\b"#, options: .regularExpression) != nil
    }

    /// Doing it again: "opnieuw", "stuur het nog een keer", "probeer het nog eens", "try again", "nochmal".
    static func retries(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard text.count <= 60 else { return false }
        return text.range(of: #"\b(opnieuw|nog (een )?keer|nog eens|nogmaals|probeer (het )?(nog|weer)|again|retry|resend|one more time|nochmal|noch (ein)?mal|erneut|encore|de nouveau|otra vez|de nuevo)\b"#, options: .regularExpression) != nil
    }

    /// A short go-ahead: "ja", "doe maar", "verzend", "send it", "ok".
    static func confirms(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard text.count <= 40 else { return false }
        return text.range(of: #"^(ja|jawel|jep|yes|yep|yeah|ok(é|e|ay)?|oké|prima|goed|klopt|akkoord|top|graag|doe maar|doe het|go|do it|sure|please|bitte|genau|mach( es| das)?|verzend|verstuur|stuur|send|schick)\b[^?]*$"#, options: .regularExpression) != nil
    }

    /// A question about messages ("wat stuurt Lisa voor berichten?"), not a request to send one. A polite request
    /// ("kun je het versturen?") still asks Nook to act.
    private static func questions(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasSuffix("?") else { return false }
        return text.range(of: #"^(nook,? )?(wil je|kun je|kan je|zou je|could you|can you|would you|will you|kannst du|könntest du)\b"#, options: .regularExpression) == nil
    }

    /// Nook's turn ends with a question to the user (suggestions below it aside).
    private static func asks(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("»") }
        return lines.last?.hasSuffix("?") ?? false
    }

    // MARK: Replies

    /// The reply says Nook set a message up to send: "Ik heb het bericht voorbereid en klaar om te sturen", "I've prepared
    /// the WhatsApp message". Only an action the user approves prepares anything, so without one this is never true.
    /// A prepared summary or overview is not a message and does not count.
    static func claimsPrepared(_ text: String) -> Bool {
        let lower = text.lowercased()
        let ready = #"\b(klaar|gereed) (om|voor) (te )?(ver)?(sturen|zenden|verzenden|versturen)\b|\bready to (be )?sen[dt]\b|\bbereit zum (senden|versenden|verschicken)\b|\bprêt à (être )?envoy|\blisto para (ser )?enviar"#
        let prepared = #"\b(ik heb|heb ik|i have|i've|ich habe|habe ich|j'ai|he)\b[^.?!]{0,60}\b(voorbereid|klaargezet|klaar gezet|opgesteld|prepared|drafted|vorbereitet|entworfen|préparé|rédigé|preparado|redactado)\b"#
        // "Een overzicht van je mail" is about mail, not a message.
        let message = #"(?<!van |of |from |von |uit |über |over |about |sur |sobre |je |your |deine |tes |tus )\b(bericht|berichtje|appje|message|nachricht|whats-?app|e-?mail|mail|mailtje|courriel|mensaje|correo)\b"#
        func has(_ pattern: String) -> Bool { lower.range(of: pattern, options: .regularExpression) != nil }
        return has(ready) || (has(prepared) && has(message))
    }

    // MARK: Tables

    /// Tools per kind, the most useful first. Action tools come before the lookups that support them.
    static let toolsByKind: [Kind: [String]] = [
        .reminder: ["create_reminder", "list_reminders", "search_reminders", "complete_reminder"],
        .event: ["create_event", "update_event", "list_events", "check_availability"],
        .availability: ["check_availability", "list_events"],
        .note: ["create_note", "search_notes", "read_note", "list_notes"],
        .todo: ["add_open_loop", "list_open_loops", "complete_open_loop", "list_reminders"],
        .mailWrite: ["compose_mail", "search_contacts", "search_mail", "read_mail"],
        .mailRead: ["inbox_mail", "search_mail", "read_mail", "mail_unread", "trash_mail", "mark_mail"],
        .contacts: ["search_contacts"],
        .music: ["media_control"],
        .volume: ["set_volume"],
        .openApp: ["open_app", "open_url", "list_app_menu", "app_menu_command"],
        .shortcut: ["run_shortcut"],
        .chart: ["show_chart"],
        .screen: ["read_screen", "read_app", "list_app_menu", "app_menu_command"],
        .control: ["read_ui", "control_ui", "app_menu_command", "list_app_menu"],
        .browser: ["read_browser_tab", "read_webpage"],
        .files: ["search_files", "read_file"],
        .github: ["github_overview", "github_search", "github_pr_details", "github_issue_details", "github_create_issue", "github_comment_issue"],
        .notion: ["notion_search", "notion_read_page"],
        .clipboard: ["read_clipboard"],
        .memory: ["remember", "forget", "recall_memory"],
        .web: ["get_weather", "search_web", "read_webpage"],
        .chatWrite: ["whatsapp_send", "whatsapp_live", "send_to_source", "search_contacts"],
        .chats: ["whatsapp_live", "search_whatsapp", "read_whatsapp", "whatsapp_open_chats", "search_messages", "read_messages", "messages_open_chats", "read_app"]
    ]

    /// Order of kinds when several match: the thing to make first, then what it is about.
    static let priority: [Kind] = [
        .memory, .chart, .mailWrite, .chatWrite, .reminder, .note, .todo, .event, .availability, .volume, .music, .control, .openApp, .shortcut,
        .contacts, .chats, .mailRead, .github, .notion, .files, .browser, .clipboard, .web, .screen
    ]

    /// The action to fill in when a request of this kind clearly asks Nook to act.
    static let actionByKind: [Kind: String] = [
        .reminder: "create_reminder", .event: "create_event", .note: "create_note", .todo: "add_open_loop",
        .mailWrite: "compose_mail", .chatWrite: "whatsapp_send", .music: "media_control", .volume: "set_volume", .openApp: "open_app",
        .shortcut: "run_shortcut", .chart: "show_chart", .memory: "remember"
    ]

    // MARK: Dates

    /// The coming days with their dates, so a small model can turn "friday at 3" into ISO 8601 without doing calendar math.
    static func dateSheet(now: Date = Date(), calendar: Calendar = .current, days: Int = 8) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        format.dateFormat = "EEEE yyyy-MM-dd"
        let offset = DateFormatter()
        offset.locale = Locale(identifier: "en_US_POSIX")
        offset.timeZone = calendar.timeZone
        offset.dateFormat = "xxx"
        let start = calendar.startOfDay(for: now)
        let lines = (0..<max(days, 1)).compactMap { day -> String? in
            guard let date = calendar.date(byAdding: .day, value: day, to: start) else { return nil }
            let label = day == 0 ? "today" : (day == 1 ? "tomorrow" : "")
            return label.isEmpty ? format.string(from: date) : "\(label): \(format.string(from: date))"
        }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = calendar.timeZone
        clock.dateFormat = "HH:mm"
        return "Dates (timezone offset \(offset.string(from: now)), now \(clock.string(from: now))): " + lines.joined(separator: "; ")
            + ". Example: friday 3 pm = \(example(now: now, calendar: calendar, format: offset))."
    }

    private static func example(now: Date, calendar: Calendar, format offset: DateFormatter) -> String {
        let start = calendar.startOfDay(for: now)
        // The next Friday (weekday 6), or today when it is Friday.
        let weekday = calendar.component(.weekday, from: start)
        let ahead = (6 - weekday + 7) % 7
        let friday = calendar.date(byAdding: .day, value: ahead, to: start) ?? start
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateFormat = "yyyy-MM-dd"
        return "\(day.string(from: friday))T15:00:00\(offset.string(from: friday))"
    }
}
