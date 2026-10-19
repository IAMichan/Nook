//! Waar een chatbericht om vraagt, herkend op het apparaat zelf voor er een model draait (Nederlands, Engels, Duits).
//!
//! Een klein lokaal model kiest slecht uit een lange lijst tools en antwoordt vaak over de context in plaats van over de
//! vraag. De intentie zegt het brein welke tools bij deze vraag horen (die komen altijd eerst), of de gebruiker wil dat
//! Nook iets *doet*, en welke ene actie ingevuld moet worden als het model niets voorstelde.

use std::collections::HashSet;

use super::matches;
use super::memory::request as memory_request;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Reminder,
    Event,
    Availability,
    Note,
    Todo,
    MailWrite,
    MailRead,
    Contacts,
    Music,
    Volume,
    OpenApp,
    Shortcut,
    Chart,
    Screen,
    Browser,
    Files,
    Github,
    Notion,
    Clipboard,
    Web,
    Chats,
    ChatWrite,
    Memory,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ChatIntent {
    /// Herkende soorten, sterkste eerst.
    pub kinds: Vec<Kind>,
    /// De gebruiker vraagt Nook iets te doen (maken, sturen, plannen, openen…), niet alleen een vraag.
    pub wants_action: bool,
    /// Een groet of bedankje: geen bronnen of tools nodig.
    pub is_small_talk: bool,
    /// "Verplaats mijn afspraak": een bestaande afspraak verandert.
    pub moves: bool,
    /// "Vergeet dat…": iets onthoudens gaat weg.
    pub forgets: bool,
    /// "Wat weet je over mij?": een vraag over wat Nook onthoudt.
    pub recalls: bool,
    /// "Wat staat er in mijn notitie over…": daar staat het antwoord, het is niet iets om te maken.
    pub reads_notes: bool,
}

/// Volgorde als er meerdere passen: eerst wat er gemaakt moet worden, dan waar het over gaat.
const PRIORITY: [Kind; 23] = [
    Kind::Memory,
    Kind::Chart,
    Kind::MailWrite,
    Kind::ChatWrite,
    Kind::Reminder,
    Kind::Note,
    Kind::Todo,
    Kind::Event,
    Kind::Availability,
    Kind::Volume,
    Kind::Music,
    Kind::OpenApp,
    Kind::Shortcut,
    Kind::Contacts,
    Kind::Chats,
    Kind::MailRead,
    Kind::Github,
    Kind::Notion,
    Kind::Files,
    Kind::Browser,
    Kind::Clipboard,
    Kind::Web,
    Kind::Screen,
];

/// Tools per soort, de nuttigste eerst; acties voor de opzoektools die ze ondersteunen.
pub fn tools_for(kind: Kind) -> &'static [&'static str] {
    match kind {
        Kind::Reminder => &["create_reminder", "list_reminders", "search_reminders", "complete_reminder"],
        Kind::Event => &["create_event", "update_event", "list_events", "check_availability"],
        Kind::Availability => &["check_availability", "list_events"],
        Kind::Note => &["create_note", "search_notes", "read_note", "list_notes"],
        Kind::Todo => &["add_open_loop", "list_open_loops", "complete_open_loop", "list_reminders"],
        Kind::MailWrite => &["compose_mail", "search_contacts", "search_mail", "read_mail"],
        Kind::MailRead => &["inbox_mail", "search_mail", "read_mail", "mail_unread"],
        Kind::Contacts => &["search_contacts"],
        Kind::Music => &["media_control"],
        Kind::Volume => &["set_volume"],
        Kind::OpenApp => &["open_app", "open_url"],
        Kind::Shortcut => &["run_shortcut"],
        Kind::Chart => &["show_chart"],
        Kind::Screen => &["read_screen", "read_app"],
        Kind::Browser => &["read_browser_tab", "read_webpage"],
        Kind::Files => &["search_files", "read_file"],
        Kind::Github => &[
            "github_overview",
            "github_search",
            "github_pr_details",
            "github_issue_details",
            "github_create_issue",
            "github_comment_issue",
        ],
        Kind::Notion => &["notion_search", "notion_read_page"],
        Kind::Clipboard => &["read_clipboard"],
        Kind::Memory => &["remember", "forget", "recall_memory"],
        Kind::Web => &["get_weather", "search_web", "read_webpage"],
        Kind::ChatWrite => &["whatsapp_send", "whatsapp_live", "send_to_source", "search_contacts"],
        Kind::Chats => &[
            "whatsapp_live",
            "search_whatsapp",
            "read_whatsapp",
            "whatsapp_open_chats",
            "search_messages",
            "read_messages",
            "messages_open_chats",
            "read_app",
        ],
    }
}

/// De actie die ingevuld wordt als een vraag van deze soort duidelijk om een actie vraagt.
fn action_for(kind: Kind) -> Option<&'static str> {
    Some(match kind {
        Kind::Reminder => "create_reminder",
        Kind::Event => "create_event",
        Kind::Note => "create_note",
        Kind::Todo => "add_open_loop",
        Kind::MailWrite => "compose_mail",
        Kind::ChatWrite => "whatsapp_send",
        Kind::Music => "media_control",
        Kind::Volume => "set_volume",
        Kind::OpenApp => "open_app",
        Kind::Shortcut => "run_shortcut",
        Kind::Chart => "show_chart",
        Kind::Memory => "remember",
        _ => return None,
    })
}

impl ChatIntent {
    pub fn is_empty(&self) -> bool {
        self.kinds.is_empty()
    }

    /// Tools die bij deze vraag horen, belangrijkste eerst. Namen kunnen tools zijn die niet gekoppeld zijn.
    pub fn tools(&self) -> Vec<&'static str> {
        let mut seen = HashSet::new();
        self.kinds.iter().flat_map(|k| tools_for(*k).iter().copied()).filter(|t| seen.insert(*t)).collect()
    }

    /// De ene actie waar deze vraag om draait, als hij daar duidelijk om vraagt.
    pub fn primary_action(&self) -> Option<&'static str> {
        if !self.wants_action {
            return None;
        }
        for kind in &self.kinds {
            // "Vat mijn notitie over X samen" leest een notitie; hij maakt er pas een als je erom vraagt.
            if *kind == Kind::Note && self.reads_notes {
                continue;
            }
            if *kind == Kind::Event && self.moves {
                return Some("update_event");
            }
            // "Wat weet je over mij?" vraagt iets; er wordt niets bewaard.
            if *kind == Kind::Memory {
                if self.forgets {
                    return Some("forget");
                }
                if self.recalls {
                    continue;
                }
            }
            if let Some(action) = action_for(*kind) {
                return Some(action);
            }
        }
        None
    }

    pub fn detect(raw: &str) -> Self {
        let text = raw.trim().to_lowercase();
        let mut intent = ChatIntent::default();
        if text.is_empty() {
            return intent;
        }
        let has = |re: &fancy_regex::Regex| matches(re, &text);

        let mut kinds: Vec<Kind> = vec![];
        // "App Lisa dat ik later ben", "stuur via WhatsApp…": een chatbericht, geen mail.
        let writes_chat = has(rx!(r"^(app|whatsapp)\s+\p{L}+(\s+\p{L}+)?\s*(:|\b(dat|om|of|that|to|if|dass|ob)\b)"))
            || has(rx!(
                r"(stuur|verstuur|beantwoord|antwoord|schrijf|send|reply|write|schick|sende|schreib)\b[^.?!]{0,60}\b(whats-?app|appje|app-?bericht)"
            ))
            || has(rx!(r"\b(via|over|per|on|through|in|über|bei) whats-?app\b"))
                && has(rx!(r"\b(stuur|verstuur|zeg|laat \p{L}+ weten|vraag|send|tell|ask|let \p{L}+ know|schick|sag|frag)"))
            || has(rx!(r"\b(app|whatsapp) (hem|haar|ze|him|her|them|ihm|ihr)\b"));
        let writes_mail = !writes_chat
            && (has(rx!(
                r"(schrijf|stuur|verstuur|beantwoord|antwoord|maak|write|send|draft|reply|answer|schreib|sende|beantworte)\b[^.?!]{0,40}\b(e-?mail|mail|mailtje|bericht)"
            )) || has(rx!(r"\b(e-?mail|mail)(tje)? (naar|aan|to|an)\b"))
                || has(rx!(r"^(mail|e-?mail) \p{L}+"))
                || has(rx!(r"\b(reply to|antwoord op|reageer op)\b")));
        // Iets blijvends onthouden is geheugen; "onthoud dat ik morgen moet bellen" is een taak en blijft een herinnering.
        let remembers = memory_request::asks_to_remember(&text);
        intent.forgets = memory_request::asks_to_forget(&text);
        intent.recalls = memory_request::asks_what_is_known(&text);
        if remembers || intent.forgets || intent.recalls {
            kinds.push(Kind::Memory);
        }
        if has(rx!(r"herinner|herinnering|\breminder|remind me|erinner|vergeet (ik )?niet|niet vergeten|don'?t forget")) {
            kinds.push(Kind::Reminder);
        }
        if has(rx!(
            r"beschikbaar|\bvrij\b|\bbezet\b|available|availability|\bfree (on|at|this|next|tomorrow|today)|am i free|verfügbar|\bfrei\b|tijd voor een|time for a"
        )) {
            kinds.push(Kind::Availability);
        }
        if has(rx!(
            r"afspra|meeting|vergader|overleg|\bcall\b|inplannen|\bplan\b[^.?!]{0,30}\bin\b|agenda|calendar|kalender|\btermin|\bevent|evenement|verplaats|reschedule|\bmove (my|the)\b|verschieb|lunch met|diner met|lunch with|dinner with"
        )) {
            kinds.push(Kind::Event);
        }
        if writes_mail {
            kinds.push(Kind::MailWrite);
        }
        if writes_chat {
            kinds.push(Kind::ChatWrite);
        }
        if has(rx!(r"notitie|noteer|\bnotes?\b|aantekening|\bmemo|notiz|schrijf (dit|het|dat) op|write (this|it|that) down")) {
            kinds.push(Kind::Note);
        }
        if has(rx!(r"\btaak\b|\btaken\b|\btodos?\b|to-do|open punt|actiepunt|nog (te )?doen|moet ik (vandaag|nog)|\btasks?\b|\baufgabe")) {
            kinds.push(Kind::Todo);
        }
        if !writes_mail && has(rx!(r"\bmails?\b|e-?mails?\b|inbox|ongelezen|unread|postvak|\bpost\b")) {
            kinds.push(Kind::MailRead);
        }
        if !writes_mail
            && !writes_chat
            && has(rx!(
                r"whats-?app|imessage|\bsms|\bchats?\b|\bchatje|\bappjes?\b|ge-?appt|\bappte|\bberichten\b(?!-?app)|\bmessages?\b|\btexts?\b|\btexted|\bnachrichten"
            ))
        {
            kinds.push(Kind::Chats);
        }
        if has(rx!(r"telefoonnummer|nummer van|mailadres|e-?mailadres|adres van|\bcontact|phone number|email address|telefonnummer")) {
            kinds.push(Kind::Contacts);
        }
        if has(rx!(r"muziek|liedje|\bnummer\b(?! van)|\bspeel|afspelen|spotify|pauzeer|\bmusic\b|\bsong|\bplay\b|\bmusik")) {
            kinds.push(Kind::Music);
        }
        if has(rx!(r"volume|\bgeluid|harder|zachter|louder|quieter|lautstärke|leiser|lauter")) {
            kinds.push(Kind::Volume);
        }
        if has(rx!(r"^(open|start|launch|öffne|starte)\s+\S+(\s+\S+)?$|\b(open|start) (de |het |the )?app\b")) {
            kinds.push(Kind::OpenApp);
        }
        if has(rx!(r"shortcut|kurzbefehl|opdracht(en)? (uitvoeren|draaien)")) {
            kinds.push(Kind::Shortcut);
        }
        if has(rx!(r"grafiek|diagram|\bchart|\bplot\b|visualiseer|visualize|staafdiagram|taartdiagram")) {
            kinds.push(Kind::Chart);
        }
        if has(rx!(
            r"scherm|\bhier\b|\bdit\b|\bdeze (mail|pagina|tekst|tabel|code)|\bthis\b|\bscreen|bildschirm|venster|\bwindow|\bdas hier"
        )) {
            kinds.push(Kind::Screen);
        }
        if has(rx!(r"browser|tabblad|\btabs?\b|webpagina|\bpagina\b|artikel|website|\bsite\b|article|webseite")) {
            kinds.push(Kind::Browser);
        }
        if has(rx!(r"bestand|document|\bpdf|\bmap\b|\bfile|folder|\bdatei|\bordner")) {
            kinds.push(Kind::Files);
        }
        if has(rx!(r"github|pull request|\bprs?\b|\bissues?\b|\brepo|\bmerge")) {
            kinds.push(Kind::Github);
        }
        if has(rx!(r"notion|\bwiki\b")) {
            kinds.push(Kind::Notion);
        }
        if has(rx!(r"klembord|clipboard|gekopieerd|\bcopied|zwischenablage|kopiert")) {
            kinds.push(Kind::Clipboard);
        }
        if has(rx!(
            r"\bzoek (op|online|op internet)|google|\bweb\b|internet|nieuws|\bweer\b|weerbericht|temperatuur|uitslag|wie won|koers|prijs van|hoeveel kost|wikipedia|openingstijden|search the web|look up online|\bnews\b|weather|who won|price of|wetter|nachrichten"
        )) {
            kinds.push(Kind::Web);
        }
        // Wat de gebruiker wil laten maken wint van waar het over gaat: "een grafiek van mijn afspraken" is een grafiek.
        kinds.sort_by_key(|k| PRIORITY.iter().position(|p| p == k).unwrap_or(99));
        intent.moves = has(rx!(r"verplaats|reschedule|\bmove (my|the)\b|verschieb|\bverzet"));
        let makes_note = has(rx!(
            r"\b(zet|schrijf|sla|bewaar|voeg|put|save|add|write|speicher)[^.?!]{0,40}\b(in|als|naar|to|into|as) (een |mijn |de |a |my )?(nieuwe |new )?(notitie|notities|note|notes)\b|\bals notitie|\bas a note|(maak|create|make|nieuwe|new|erstelle) (een |a |eine )?(nieuwe |new |neue )?(notitie|note|notiz)\b|\bnoteer|schrijf (dit|het|dat) op|write (this|it|that) down|neue notiz"
        ));
        let reads_note = has(rx!(
            r"(in|uit|from|aus) (mijn|de|m'n|my|the|meine?n?) (\w+ )?(notitie|notities|notes?|notiz\w*)|(lees|zoek|vind|vat|samenvat\w*|wat staat|wat stond|read|search|find|summari[sz]e|what does|lies|such|finde)[^.?!]{0,40}(notitie|notities|notes?|notiz\w*)"
        ));
        intent.reads_notes = reads_note && !makes_note;

        let polite = rx!(r"^(nook|hé nook|hey nook|hoi nook|hi nook)[ ,]+").replace(&text, "").to_string();
        let polite =
            rx!(r"^(wil je|kun je|kan je|zou je|could you|can you|would you|will you|please|graag|kannst du|könntest du|bitte)\s+")
                .replace(&polite, "")
                .to_string();
        let imperative = matches(
            rx!(
                r"^(maak|zet|plan|boek|stuur|verstuur|schrijf|noteer|voeg|herinner|onthoud|vergeet|open|start|speel|pauzeer|verplaats|annuleer|mail|app|whatsapp|beantwoord|teken|create|make|add|schedule|book|send|write|remind|remember|forget|note|put|set|move|cancel|draft|reply|play|pause|draw|merk|vergiss|erstelle|schreib|erinnere|plane|trag|sende|öffne|spiele)\b"
            ),
            &polite,
        );
        let asks_politely =
            has(rx!(r"^(nook,? )?(wil je|kun je|kan je|zou je|could you|can you|would you|will you|kannst du|könntest du)\b"));
        let embedded = has(rx!(
            r"herinner me|remind me|erinnere mich|zet (het|dit|dat|een|'?n)?[^.?!]{0,40} in (mijn|de) (agenda|herinneringen|notities)|vergeet (ik )?niet|\bmaak (een|er een)\b|\bplan (een|het|dat)\b|\bstuur (een|het|dat)\b|\bschrijf (een|het|dat)\b|\bvoeg [^.?!]{0,30} toe\b|\bvoortaan\b|\bfrom now on\b|\bab jetzt\b"
        ));
        intent.wants_action = !kinds.is_empty() && (imperative || asks_politely || embedded);

        let greeting = has(rx!(
            r"^(hoi|hallo|hey|hi|hello|yo|goedemorgen|goedemiddag|goedenavond|dank( je)?( wel)?|bedankt|thanks|thank you|thx|ok(é|e|ay)?|top|super|prima|cool|nice|haha|moin|guten (morgen|tag|abend)|danke)\b[\s\p{P}\p{So}]*(nook)?[\s\p{P}\p{So}]*$"
        ));
        intent.is_small_talk = kinds.is_empty() && greeting;
        intent.kinds = kinds;
        intent
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn action(text: &str) -> Option<&'static str> {
        ChatIntent::detect(text).primary_action()
    }

    #[test]
    fn actions_in_dutch() {
        assert_eq!(action("Herinner me morgen om 9 uur aan de tandarts"), Some("create_reminder"));
        assert_eq!(action("Zet vrijdag om 15:00 een afspraak met Lisa in mijn agenda"), Some("create_event"));
        assert_eq!(action("Plan een meeting met Jan op maandag om 10 uur"), Some("create_event"));
        assert_eq!(action("Verplaats mijn afspraak met Lisa naar maandag"), Some("update_event"));
        assert_eq!(action("Stuur een mail naar Lisa dat ik later ben"), Some("compose_mail"));
        assert_eq!(action("Maak een notitie: boodschappen melk en eieren"), Some("create_note"));
        assert_eq!(action("Kun je een taak toevoegen om de offerte af te maken?"), Some("add_open_loop"));
        assert_eq!(action("Nook, vergeet niet dat ik de huur moet betalen"), Some("create_reminder"));
    }

    #[test]
    fn actions_in_english_and_german() {
        assert_eq!(action("Remind me to call Jan tomorrow"), Some("create_reminder"));
        assert_eq!(action("Can you schedule a meeting with Lisa on Friday at 3?"), Some("create_event"));
        assert_eq!(action("Write an email to Tom about the invoice"), Some("compose_mail"));
        assert_eq!(action("Erinnere mich morgen an den Zahnarzt"), Some("create_reminder"));
    }

    #[test]
    fn what_to_make_wins_over_what_it_is_about() {
        assert_eq!(action("Maak een grafiek van mijn afspraken per dag"), Some("show_chart"));
        assert_eq!(action("Stuur Lisa een mail over de meeting van vrijdag"), Some("compose_mail"));
        assert_eq!(action("Herinner me aan de call met Jan"), Some("create_reminder"));
        assert_eq!(action("Zet de muziek wat zachter"), Some("set_volume"));
        assert_eq!(action("Open de pull request van Jan"), None);
        assert_eq!(action("open Safari"), Some("open_app"));
    }

    #[test]
    fn questions_are_not_actions() {
        assert_eq!(action("Ben ik vrijdag vrij?"), None);
        assert_eq!(action("Wat staat er morgen in mijn agenda?"), None);
        assert_eq!(action("Heb ik nog ongelezen mail van Lisa?"), None);
        assert_eq!(action("Wat is de hoofdstad van Frankrijk?"), None);
        assert_eq!(ChatIntent::detect("Ben ik vrijdag vrij?").tools().first(), Some(&"check_availability"));
        assert!(ChatIntent::detect("Heb ik nog ongelezen mail?").tools().contains(&"inbox_mail"));
    }

    #[test]
    fn small_talk() {
        assert!(ChatIntent::detect("Hoi!").is_small_talk);
        assert!(ChatIntent::detect("Bedankt Nook").is_small_talk);
        assert!(ChatIntent::detect("thanks!").is_small_talk);
        assert!(!ChatIntent::detect("Hoi, ben ik morgen vrij?").is_small_talk);
        assert!(ChatIntent::detect("Wat is de hoofdstad van Frankrijk?").is_empty());
    }

    #[test]
    fn memory_requests() {
        assert_eq!(action("Onthoud dat Lisa mijn vrouw is"), Some("remember"));
        assert_eq!(action("Vergeet dat ik in Utrecht woon"), Some("forget"));
        assert_eq!(action("Wat weet je over mij?"), None);
    }

    #[test]
    fn tools_of_the_action_come_first() {
        let tools = ChatIntent::detect("Herinner me aan de call met Jan").tools();
        assert_eq!(tools.first(), Some(&"create_reminder"));
        assert_eq!(tools.iter().collect::<HashSet<_>>().len(), tools.len());
    }
}
