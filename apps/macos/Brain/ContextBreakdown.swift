import Foundation

/// What goes into the model for one answer, part by part, with its size: the context inspector shows this so the user
/// sees exactly what the model reads (instructions, memory, what was looked up) and how much room it takes.
struct ContextBreakdown: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case style, space, memory, lookedUp, overview
    }

    struct Part: Equatable, Identifiable, Sendable {
        var kind: Kind
        var text: String
        var id: String { kind.rawValue }
        var characters: Int { text.count }
        var tokens: Int { ContextBreakdown.estimateTokens(text) }
    }

    var parts: [Part]
    /// The model's window in tokens; 0 when unknown.
    var budget: Int

    /// Parts with something in them only, in the order the model reads them.
    init(parts: [Part], budget: Int = 0) {
        self.parts = parts.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.budget = budget
    }

    var totalTokens: Int { parts.reduce(0) { $0 + $1.tokens } }
    var totalCharacters: Int { parts.reduce(0) { $0 + $1.characters } }

    /// 0…1 of the window used; nil when the window is unknown.
    var fill: Double? { budget > 0 ? min(1, Double(totalTokens) / Double(budget)) : nil }

    /// The part's share of the whole, 0…1.
    func share(of part: Part) -> Double { totalTokens > 0 ? Double(part.tokens) / Double(totalTokens) : 0 }

    /// About four characters to a token for Latin text; a rough size, said as an estimate everywhere it is shown.
    static func estimateTokens(_ text: String) -> Int { (text.count + 3) / 4 }
}
