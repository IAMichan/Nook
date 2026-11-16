import Foundation

extension AppModel {
    /// The parts of what the model reads for one answer, for the context inspector: the instructions of the conversation,
    /// what Nook remembered, what it looked up, and the rest of the overview (the sources and what the user wants).
    static func contextBreakdown(instructions: [String], prepared: PreparedRun, budget: Int) -> ContextBreakdown {
        let memory = MemoryBook.section(prepared.memories)
        let lookedUp = prepared.fetched.joined(separator: "\n\n")
        var overview = prepared.context
        for piece in [memory] + prepared.fetched where !piece.isEmpty {
            overview = overview.replacingOccurrences(of: piece, with: "")
        }
        func lines(_ prefix: String) -> String { instructions.filter { $0.hasPrefix(prefix) }.joined(separator: "\n") }
        return ContextBreakdown(parts: [
            .init(kind: .style, text: lines("Answer style")),
            .init(kind: .space, text: lines("Instructions of the space")),
            .init(kind: .memory, text: memory),
            .init(kind: .lookedUp, text: lookedUp),
            .init(kind: .overview, text: overview),
        ], budget: budget)
    }
}
