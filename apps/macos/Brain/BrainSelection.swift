import Foundation

/// Where Nook's thinking happens.
enum BrainRuntime: String, Codable, Equatable {
    /// The built-in model (MLX), on this Mac.
    case mlx
    /// Ollama on this Mac.
    case ollama
    /// LM Studio on this Mac.
    case lmstudio
    /// An external service the user chose on purpose (Claude, OpenAI, Claude Code, …).
    case external

    var isLocal: Bool { self != .external }
}

/// The one answer to "which brain is active": a runtime, the model on it, and for an external service which one.
///
/// It is derived from the stored settings (`useLocal`, `provider`, `localModel`, per-provider models), which stay as
/// they are so a downgrade keeps working. Everything that decides how to run a request reads this instead of
/// combining the separate settings itself.
struct BrainSelection: Equatable {
    var runtime: BrainRuntime
    /// Only for `.external` and the local servers: the provider the model belongs to.
    var provider: AIProvider
    var model: String

    var isLocal: Bool { runtime.isLocal }

    static func resolve(useLocal: Bool, provider: AIProvider, localModel: String, providerModel: String) -> BrainSelection {
        if useLocal { return BrainSelection(runtime: .mlx, provider: provider, model: localModel) }
        switch provider {
        case .ollama: return BrainSelection(runtime: .ollama, provider: provider, model: providerModel)
        case .lmstudio: return BrainSelection(runtime: .lmstudio, provider: provider, model: providerModel)
        default: return BrainSelection(runtime: .external, provider: provider, model: providerModel)
        }
    }

    /// The stored settings that express this selection.
    var storedValues: (useLocal: Bool, provider: AIProvider) {
        switch runtime {
        case .mlx: return (true, provider.isLocalServer ? .claude : provider)
        case .ollama: return (false, .ollama)
        case .lmstudio: return (false, .lmstudio)
        case .external: return (false, provider)
        }
    }

    /// First start of a version that knows about local-first: a new install thinks on the Mac itself; someone who already
    /// chose an external AI (a provider or an Anthropic key was set) keeps it. Nothing is switched without the user.
    static func initialUseLocal(stored: Bool?, storedProvider: String?, hasAnthropicKey: Bool) -> Bool {
        if let stored { return stored }
        let choseExternal = storedProvider != nil || hasAnthropicKey
        return !choseExternal
    }
}

/// Screen work on this Mac while an external brain answers the rest (Settings › Brain › Screen work).
///
/// With Claude (or another external AI) as the brain and the screen kept on this Mac, everything that reads the screen
/// would otherwise stop: thinking along, looking at the screen, Double Tap, taking over a task, and questions about what is
/// on screen. With a screen brain picked, that work runs on a model on this Mac instead, so screen text never leaves it,
/// while every other question still goes to the stronger external brain.
enum ScreenBrain {
    /// The brain a run uses instead of the chosen one: set for screen work (`AppModel.onScreenBrain`), read by
    /// `AppSettings.selection`, so every step of that run (context, tools, privacy filter, model) follows it.
    @TaskLocal static var routed: BrainSelection?

    /// The stored choice: "" for none, otherwise the runtime and the model ("mlx:<id>", "ollama:<model>", "lmstudio:<model>").
    static func parse(_ stored: String) -> BrainSelection? {
        guard let colon = stored.firstIndex(of: ":") else { return nil }
        let model = String(stored[stored.index(after: colon)...])
        guard !model.isEmpty else { return nil }
        switch stored[..<colon] {
        case "mlx": return BrainSelection(runtime: .mlx, provider: .claude, model: model)
        case "ollama": return BrainSelection(runtime: .ollama, provider: .ollama, model: model)
        case "lmstudio": return BrainSelection(runtime: .lmstudio, provider: .lmstudio, model: model)
        default: return nil
        }
    }

    /// The value `parse` reads back; "" for a brain that is not on this Mac, which never does screen work.
    static func stored(_ selection: BrainSelection) -> String {
        selection.isLocal ? "\(selection.runtime.rawValue):\(selection.model)" : ""
    }

    /// The brain that does the screen work: only while the chosen brain is external and the screen is kept on this Mac.
    /// Nil otherwise: a brain on this Mac already does everything, and a screen the external brain may read needs no other.
    static func worker(chosen: BrainSelection, screenPrivate: Bool, stored: String) -> BrainSelection? {
        guard !chosen.isLocal, screenPrivate else { return nil }
        return parse(stored)
    }

    // MARK: Which questions are screen work

    /// Words that may point at something on screen. "Daarna", "daarom", "hierna" and "hiervoor" only look like them.
    private static let cue = try? NSRegularExpression(
        pattern: #"\b(hier(?!na|voor|door|mee|bij|naast|om)\w*|dit|deze|daar(?!na|om|door|voor|mee|naast|entegen|bij)\w*|erbij|ervoor|ervan|erover|scherm|kijk mee|lees mee)\b|\ber\b.{0,25}\b(afspraak|herinnering|taak|mail|punt|agenda)\b"#,
        options: [.caseInsensitive]
    )
    /// Words that can only mean the screen, whatever was said before: in a conversation "dit" and "ervan" usually point
    /// at the conversation itself.
    private static let plainCue = try? NSRegularExpression(
        pattern: #"\b(hier|hierin|hierop|scherm\w*|kijk mee|lees mee|deze (mail|pagina|tekst|tabel|code|site|website|foto|afbeelding))\b"#,
        options: [.caseInsensitive]
    )
    /// "Deze week" or "dit jaar" names a period, not something on screen.
    private static let period = try? NSRegularExpression(
        pattern: #"\b(dit|deze)\s+(week|weekend|maand|jaar|kwartaal|ochtend|middag|avond|nacht|keer)\b"#,
        options: [.caseInsensitive]
    )
    /// A word that leans on what was just said: "en de tweede?", "vertaal het", "wat staat er verder?".
    private static let leaning = try? NSRegularExpression(
        pattern: #"^(en|maar|ook|and|but|also|und|aber)\b|\b(het|die|dat|ze|hij|zij|hem|haar|er|verder|meer|nog|it|that|those|them|he|she|more|else|es|das|sie|er|mehr)\b"#,
        options: [.caseInsensitive]
    )

    private static func matches(_ pattern: NSRegularExpression?, _ text: String) -> Bool {
        pattern?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func withoutPeriods(_ text: String) -> String {
        period?.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") ?? text
    }

    /// The question may point at what is on screen.
    static func refersToScreen(_ text: String) -> Bool {
        matches(cue, withoutPeriods(text))
    }

    /// A follow-up on an answer that read the screen: it leans on that answer and asks for nothing of its own. "Wat is
    /// mijn IP-adres?" or "zet in de agenda dat ik om 11 uur bel" start something new, even right after such an answer.
    static func followsUp(_ text: String) -> Bool {
        let kinds = ChatIntent.detect(text).kinds.filter { $0 != .screen }
        return kinds.isEmpty && text.split(whereSeparator: \.isWhitespace).count <= 8 && matches(leaning, text)
    }

    /// The question needs the screen and something the chosen brain can look up ("klopt wat hier staat met de mail van
    /// Henk?"). The chosen brain then does its part first without the screen, and the screen brain finishes the answer on
    /// this Mac. A request to act stays with the screen brain: only the text on screen can fill it in.
    static func needsBoth(_ text: String) -> Bool {
        let intent = ChatIntent.detect(text)
        guard intent.primaryAction == nil else { return false }
        return !Set(intent.kinds).isDisjoint(with: [.mailRead, .chats, .github, .notion, .web, .files, .todo])
    }

    /// What the chosen brain is told when it does its part without the screen.
    static let outsideInstruction = "Part of this question is about the user's screen or another source kept on their Mac, which you cannot see and must not ask about: a model on the Mac handles that part. Do only the rest: look up what is needed and write the facts you found, briefly, with names, dates and amounts. Do not ask anything back and do not say what you cannot see."

    /// Whether the chosen brain can answer this from a filtered note (`PrivateBrief`). A question for a phone number or an
    /// address asks for exactly what the note takes out: the model on this Mac answers that itself. The same for one that
    /// came with pictures: only a brain that gets them can say what is on them, and `ScreenBrain.routed` already fixed a run.
    static func relays(_ text: String, images: Bool) -> Bool {
        routed == nil && !images && !ChatIntent.detect(text).kinds.contains(.contacts)
    }

    /// Whether this chat question is screen work. The screen brain is usually far smaller than the chosen brain, so a
    /// question goes there only when it needs the screen. Anything else stays with the chosen brain.
    /// `conversation`: earlier turns exist, so "dit" and "ervan" can point at those. `afterScreen`: the last answer read the screen.
    static func handles(_ text: String, conversation: Bool, afterScreen: Bool) -> Bool {
        if matches(plainCue, withoutPeriods(text)) { return true }
        if !conversation, refersToScreen(text) { return true }
        return afterScreen && followsUp(text)
    }
}
