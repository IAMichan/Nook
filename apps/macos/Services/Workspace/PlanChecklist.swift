import Foundation

/// A plan as a checklist you can edit before it runs: each list item of the plan's Markdown is a step you can leave out,
/// and what is carried out is the plan with only the steps you kept. The same for every agent: the plan is the agent's
/// own text (Claude Code's ExitPlanMode, a Codex plan, an ACP agent's plan), so no agent is special here.
struct PlanChecklist: Equatable {
    struct Step: Equatable, Identifiable {
        /// The line's index in the plan text.
        let id: Int
        let text: String
        let indent: Int
        var kept = true
    }

    private(set) var lines: [String]
    private(set) var steps: [Step]

    init(markdown: String) {
        lines = markdown.components(separatedBy: "\n")
        steps = []
        var inFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle() }
            guard !inFence, let item = Self.item(line) else { continue }
            steps.append(Step(id: index, text: item.text, indent: item.indent))
        }
    }

    /// A checklist is worth showing from two steps.
    var isUseful: Bool { steps.count >= 2 }
    /// Steps that will run: kept themselves and not under a step you left out.
    var keptCount: Int {
        var count = 0
        var leftOutIndent: Int?
        for step in steps {
            if let indent = leftOutIndent, step.indent > indent { continue }
            leftOutIndent = nil
            if step.kept { count += 1 } else { leftOutIndent = step.indent }
        }
        return count
    }
    var allKept: Bool { steps.allSatisfy(\.kept) }

    mutating func toggle(_ id: Int) {
        guard let i = steps.firstIndex(where: { $0.id == id }) else { return }
        steps[i].kept.toggle()
    }

    /// The plan without the steps you left out (and without their indented sub-steps).
    var text: String {
        var dropped = Set<Int>()
        for step in steps where !step.kept {
            dropped.insert(step.id)
            var next = step.id + 1
            while next < lines.count, let child = Self.item(lines[next]), child.indent > step.indent {
                dropped.insert(next)
                next += 1
            }
        }
        return lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element).joined(separator: "\n")
    }

    /// Live progress while the plan runs: the share of the plan's steps the agent's task list has finished.
    static func progress(done: Int, total: Int) -> Double {
        total <= 0 ? 0 : min(1, Double(max(0, done)) / Double(total))
    }

    private static func item(_ line: String) -> (text: String, indent: Int)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.count
        let rest = line.dropFirst(indent)
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            return (strip(rest.dropFirst(2)), indent)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") { return (strip(after.dropFirst(2)), indent) }
        }
        return nil
    }

    private static func strip<S: StringProtocol>(_ s: S) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for box in ["[ ] ", "[x] ", "[X] "] where t.hasPrefix(box) { t = String(t.dropFirst(box.count)) }
        return t
    }
}
