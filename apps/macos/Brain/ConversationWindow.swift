import Foundation

/// The part of a conversation that goes to the brain with a new question, within a fixed size.
///
/// A long conversation used to send its newest sixteen messages at up to 4,000 characters each (up to 64,000 characters
/// with every question, whatever the brain), and to forget everything before them. The window instead:
///
/// - keeps the newest turns in full, so "and on Friday?" or "make it shorter" still sees what it refers to;
/// - shortens older turns to their start, so they cost little but still say what was asked and answered;
/// - folds the turns that no longer fit into one recap turn that lists what the user asked earlier, so the topic a
///   conversation started with is never lost when the user picks it up again;
/// - stays within `budget` characters in total.
///
/// Foundation-only and deterministic, tested in `ConversationWindowTests`.
enum ConversationWindow {
    struct Limits: Equatable {
        /// Characters for the whole window, recap included.
        var budget: Int = 24_000
        /// The newest turns that keep up to `fullLength` characters.
        var recentTurns: Int = 6
        var fullLength: Int = 4_000
        /// Older turns keep their first `shortLength` characters.
        var shortLength: Int = 600
        /// Turns at most, before the rest is folded into the recap.
        var maxTurns: Int = 20
        /// Earlier questions the recap lists at most (the first ones and the latest ones before the window).
        var recapQuestions: Int = 6
        var recapQuestionLength: Int = 140

        static let standard = Limits()

        /// Sized to the model: a sixth of what its prompt can hold goes to the conversation, between 3,000 and 32,000
        /// characters, so a 4k on-device model is not handed the window of a cloud model, and a cloud model gets more
        /// room than before without paying for a whole long conversation with every question.
        static func fitting(_ profile: ModelProfile) -> Limits {
            var limits = Limits()
            limits.budget = min(32_000, max(3_000, profile.promptCharacterBudget / 6))
            limits.fullLength = min(4_000, max(800, limits.budget / 3))
            limits.shortLength = min(600, max(200, limits.budget / 20))
            if profile.isSmall && !profile.richPrompt {
                limits.recentTurns = 4
                limits.maxTurns = 12
                limits.recapQuestions = 4
            }
            return limits
        }
    }

    /// How the recap starts, so the code that reads the newest turns (`ChatIntent`, `Research`) can leave it out.
    static let recapHeader = "[Earlier in this conversation (shortened), the user asked:"
    static let recapFooter = "\n]"

    /// The turns to send, oldest first. The recap, when there is one, is the first turn and comes from the user's side,
    /// so every provider accepts it as the start of the conversation.
    static func fit(_ turns: [ChatTurn], limits: Limits = .standard) -> [ChatTurn] {
        let turns = turns.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !turns.isEmpty else { return [] }

        // Newest first: each turn gets its length by how recent it is, until the budget or the turn limit is reached.
        var kept: [ChatTurn] = []
        var used = 0
        var cut = turns.count
        for (offset, turn) in turns.reversed().enumerated() {
            guard kept.count < limits.maxTurns else { break }
            let length = offset < limits.recentTurns ? limits.fullLength : limits.shortLength
            var text = shortened(turn.text, to: length)
            let left = limits.budget - used
            if text.count > left {
                // The newest turn always comes along, cut to what fits; an older one that does not fit ends the window.
                guard kept.isEmpty, left > 0 else { break }
                text = shortened(turn.text, to: left)
            }
            kept.append(ChatTurn(fromUser: turn.fromUser, text: text))
            used += text.count
            cut = turns.count - 1 - offset
        }
        kept.reverse()

        // Turns that fell out of the window: what the user asked there, as one short recap at the start. When the recap
        // does not fit next to the window, the oldest kept turns make room for it (and join the recap themselves).
        var recapText = recap(of: Array(turns[..<cut]), limits: limits)
        while let text = recapText, used + text.count + 2 > limits.budget, kept.count > 1 {
            used -= kept.removeFirst().text.count
            cut += 1
            recapText = recap(of: Array(turns[..<cut]), limits: limits)
        }
        guard let recapText else { return kept }
        // The recap speaks for the user, so the window always starts on the user's side: it joins a first user turn,
        // or comes before a first answer as a turn of its own.
        if let first = kept.first, first.fromUser {
            kept[0] = ChatTurn(fromUser: true, text: recapText + "\n\n" + first.text)
            return kept
        }
        return [ChatTurn(fromUser: true, text: recapText)] + kept
    }

    /// One line per earlier question, the first ones (where the topic was set) and the latest ones before the window.
    static func recap(of dropped: [ChatTurn], limits: Limits = .standard) -> String? {
        let questions = dropped.filter(\.fromUser).map { oneLine($0.text, limit: limits.recapQuestionLength) }.filter { !$0.isEmpty }
        guard !questions.isEmpty, limits.recapQuestions > 0 else { return nil }
        let picked: [String]
        var skipped = 0
        if questions.count <= limits.recapQuestions {
            picked = questions
        } else {
            let head = (limits.recapQuestions + 1) / 2
            let tail = limits.recapQuestions - head
            picked = Array(questions.prefix(head)) + Array(questions.suffix(tail))
            skipped = questions.count - picked.count
        }
        var lines = [recapHeader]
        for (index, question) in picked.enumerated() {
            if skipped > 0, index == (limits.recapQuestions + 1) / 2 { lines.append("- … \(skipped) more") }
            lines.append("- " + question)
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    /// The turns without the recap: what the user really said in the newest turns. The recap lists questions from long
    /// ago, so reading it as the latest request would carry an old "send it to Anna" into a new question, or search for
    /// an old topic when the user asks "and the budget?".
    static func withoutRecap(_ turns: [ChatTurn]) -> [ChatTurn] {
        turns.compactMap { turn in
            guard turn.fromUser, turn.text.hasPrefix(recapHeader) else { return turn }
            guard let end = turn.text.range(of: recapFooter) else { return nil }
            let rest = turn.text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? nil : ChatTurn(fromUser: true, text: rest)
        }
    }

    /// The text cut at a word near `length`, marked with an ellipsis when something was left out.
    static func shortened(_ text: String, to length: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > length else { return text }
        guard length > 1 else { return "…" }
        let head = text.prefix(length - 1)
        // Back to the last space when it is close, so a word is not cut in half.
        if let space = head.lastIndex(where: { $0 == " " || $0 == "\n" }), head.distance(from: space, to: head.endIndex) <= 40 {
            return String(head[..<space]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return String(head) + "…"
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
        return shortened(flat, to: limit)
    }
}
