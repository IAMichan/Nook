import Foundation

/// How Nook words its answers, switchable per conversation (concise, explanatory, formal, casual). The style only changes
/// the voice and the length: facts, sources and the user's language stay as they are. It reaches the model as one short
/// line of instructions in the context (`ResponseStyle.contextLine`), through the same pipeline as every other answer.
enum ResponseStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard, concise, explanatory, formal, casual

    var id: String { rawValue }

    /// The sentence the brain gets; nil for the standard style, which adds nothing.
    var instruction: String? {
        switch self {
        case .standard: return nil
        case .concise: return "Answer as briefly as you can: the answer first, no preamble, no recap, a short list only when it helps."
        case .explanatory: return "Explain your answer: give the reasoning and the steps behind it in plain words, with a small example when it helps."
        case .formal: return "Write formally and politely: complete sentences, no slang, no emoji, no contractions."
        case .casual: return "Write casually and warmly, like a friend: short sentences, plain words, no stiff phrasing."
        }
    }

    /// The text for the context of the model: nothing for the standard style.
    var contextLine: String? { instruction.map { "Answer style chosen by the user for this conversation: " + $0 } }
}

/// The style of each conversation, kept on this Mac. A conversation with no choice of its own follows `defaultStyle`.
final class ResponseStyleStore: @unchecked Sendable {
    static let shared = ResponseStyleStore()

    static let defaultsKey = "nook.responseStyle.byConversation"
    static let defaultStyleKey = "nook.responseStyle.default"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var defaultStyle: ResponseStyle {
        get { defaults.string(forKey: Self.defaultStyleKey).flatMap(ResponseStyle.init(rawValue:)) ?? .standard }
        set { defaults.set(newValue.rawValue, forKey: Self.defaultStyleKey) }
    }

    /// The style a conversation answers in now.
    func style(for conversation: UUID) -> ResponseStyle {
        lock.lock(); defer { lock.unlock() }
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]
        return stored?[conversation.uuidString].flatMap(ResponseStyle.init(rawValue:)) ?? defaultStyle
    }

    /// Choosing the default style again takes the conversation's own choice away, so it follows the default.
    func set(_ style: ResponseStyle, for conversation: UUID) {
        lock.lock(); defer { lock.unlock() }
        var stored = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        if style == defaultStyle { stored[conversation.uuidString] = nil } else { stored[conversation.uuidString] = style.rawValue }
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    /// A deleted conversation leaves nothing behind.
    func forget(_ conversation: UUID) {
        lock.lock(); defer { lock.unlock() }
        var stored = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        guard stored.removeValue(forKey: conversation.uuidString) != nil else { return }
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}
