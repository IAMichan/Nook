import Foundation

/// The settings Nook's chat may read and change, and how a value said in words ("aan", "off", "zwevend", "Engels") becomes
/// one the setting takes. Foundation-only, so it is tested on its own (SettingsCatalogTests); `AppModel+SettingsTools`
/// reads and writes the real settings.
///
/// Left out on purpose: anything that lets Nook act without asking (small things right away) or that sends more out of the
/// Mac (the brain, its provider, the sources kept on this Mac). Those stay a click in Settings.
enum SettingsCatalog {
    enum Kind: Equatable {
        case toggle
        case choice([String])
    }

    struct Entry: Equatable {
        let id: String
        let kind: Kind
        /// The Settings section it lives in (a `SettingsSection` raw value).
        let section: String
        /// What it does, for the model.
        let about: String
    }

    static let entries: [Entry] = [
        Entry(id: "app_language", kind: .choice(["en", "nl", "de", "fr", "es"]), section: "general",
              about: "Language of Nook's own screens and buttons."),
        Entry(id: "answer_language", kind: .choice(["en", "nl", "de", "fr", "es", "auto"]), section: "general",
              about: "Language Nook answers in; auto is the language of the question."),
        Entry(id: "nook_style", kind: .choice(["minimal", "classic", "playful"]), section: "appearance",
              about: "How Nook's face looks: minimal (dots, no mouth), classic (the usual look) or playful (round eyes, a talking mouth)."),
        Entry(id: "notch_placement", kind: .choice(["notch", "floating"]), section: "general",
              about: "Nook in the notch, or floating anywhere on screen."),
        Entry(id: "notch_on_all_screens", kind: .toggle, section: "general", about: "A notch on every connected screen."),
        Entry(id: "hide_when_idle", kind: .toggle, section: "general", about: "Hide Nook when there is nothing to show."),
        Entry(id: "open_on_hover", kind: .toggle, section: "general", about: "Open the panel when pointing at the notch."),
        Entry(id: "energy_mode", kind: .choice(["automatic", "saver", "full"]), section: "general",
              about: "How much Nook does by himself on battery or a busy Mac: automatic (steps back when needed), saver (always light) or full (never slows down)."),
        Entry(id: "web_search", kind: .toggle, section: "assistant", about: "Search the web when a question needs it."),
        Entry(id: "think_along", kind: .toggle, section: "assistant",
              about: "Proactive suggestions next to the notch while the user works."),
        Entry(id: "track_screens", kind: .toggle, section: "assistant",
              about: "Read the text of all windows on all screens, on the Mac, so answers are ready at once."),
        Entry(id: "screens_with_every_question", kind: .toggle, section: "assistant",
              about: "Use the screens with every question, not only when the user points at something."),
        Entry(id: "speak_answers", kind: .toggle, section: "dictation", about: "Read answers aloud after a spoken question."),
        Entry(id: "wake_word", kind: .toggle, section: "dictation", about: "Listen for \"Hey Nook\"."),
        Entry(id: "dictation", kind: .toggle, section: "dictation", about: "Dictate anywhere by holding a key."),
        Entry(id: "agent_sounds", kind: .toggle, section: "notifications", about: "A sound when an agent waits or is done."),
        Entry(id: "agent_notice", kind: .choice(["detailed", "compact"]), section: "notifications",
              about: "The notch card when an agent is done or waits: detailed (its summary and changes) or compact (one line)."),
        Entry(id: "use_memory", kind: .toggle, section: "memory", about: "Use what Nook remembers with every question."),
        Entry(id: "learn_from_chats", kind: .toggle, section: "memory", about: "Let Nook learn from conversations by itself."),
        Entry(id: "online_lyrics", kind: .toggle, section: "privacy", about: "Look up song lyrics online.")
    ]

    static var ids: [String] { entries.map(\.id) }

    static func entry(_ id: String) -> Entry? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.first { $0.id == key }
    }

    /// The value a setting takes for what was asked: "on"/"off" for a switch, one of the options for a choice. Nil when it
    /// does not fit.
    static func value(_ raw: String, for entry: Entry) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch entry.kind {
        case .toggle:
            if onWords.contains(text) { return "on" }
            if offWords.contains(text) { return "off" }
            return nil
        case .choice(let options):
            if options.contains(text) { return text }
            guard let alias = aliases[text], options.contains(alias) else { return nil }
            return alias
        }
    }

    static func value(_ flag: Bool) -> String { flag ? "on" : "off" }

    static let onWords: Set<String> = ["on", "true", "yes", "1", "enable", "enabled", "aan", "ja", "an", "ein", "oui", "activé", "sí", "si"]
    static let offWords: Set<String> = ["off", "false", "no", "0", "disable", "disabled", "uit", "nee", "aus", "nein", "non", "désactivé", "apagado"]

    /// Language names in the five languages, the two placements and the three styles.
    static let aliases: [String: String] = [
        "english": "en", "engels": "en", "englisch": "en", "anglais": "en", "inglés": "en", "ingles": "en",
        "dutch": "nl", "nederlands": "nl", "niederländisch": "nl", "néerlandais": "nl", "neerlandés": "nl",
        "german": "de", "duits": "de", "deutsch": "de", "allemand": "de", "alemán": "de", "aleman": "de",
        "french": "fr", "frans": "fr", "französisch": "fr", "français": "fr", "francais": "fr", "francés": "fr",
        "spanish": "es", "spaans": "es", "spanisch": "es", "espagnol": "es", "español": "es", "espanol": "es",
        "floating": "floating", "zwevend": "floating", "schwebend": "floating", "flottant": "floating", "flotante": "floating",
        "in the notch": "notch", "in de notch": "notch", "in der notch": "notch",
        "minimaal": "minimal", "minimaliste": "minimal", "minimalista": "minimal", "minimalistisch": "minimal",
        "klassiek": "classic", "klassisch": "classic", "classique": "classic", "clásico": "classic", "clasico": "classic",
        "speels": "playful", "verspielt": "playful", "ludique": "playful", "divertido": "playful", "fun": "playful",
        "auto": "automatic", "automatisch": "automatic", "automatique": "automatic", "automático": "automatic", "automatico": "automatic",
        "zuinig": "saver", "spaarstand": "saver", "battery saver": "saver", "sparsam": "saver", "économe": "saver", "econome": "saver",
        "ahorro": "saver", "eco": "saver",
        "full power": "full", "volle kracht": "full", "volle kraft": "full", "pleine puissance": "full", "máxima potencia": "full",
        "maxima potencia": "full", "performance": "full"
    ]

    /// The arguments of `change_setting`.
    static var changeSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "setting": ["type": "string", "enum": ids, "description": "Which setting."],
                "value": ["type": "string", "description": "on or off for a switch; for a choice one of its options (see get_settings)."]
            ],
            "required": ["setting", "value"]
        ]
    }

    /// The result of a change, with the old value so it can be undone: "web_search: on (was off)".
    static func result(_ id: String, value: String, old: String) -> String {
        "\(id): \(value) (was \(old))"
    }

    /// The old value in a result made by `result`.
    static func previous(in result: String) -> String? {
        guard let range = result.range(of: #"\(was ([^)\s]+)\)"#, options: .regularExpression) else { return nil }
        let old = result[range].dropFirst(5).dropLast()
        return old.isEmpty ? nil : String(old)
    }
}
