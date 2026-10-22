import Foundation

/// A plan as saved: each step's tool, input, and outcome, and where the plan as a whole stood.
struct StoredPlan: Codable, Equatable {
    struct Step: Codable, Equatable {
        var tool: String
        /// How the step read in the plan, used when the tool is no longer known (or for plans saved as text).
        var summary: String
        /// The tool input as a JSON object.
        var input: String?
        var state: ActionStepState
        var included: Bool
    }

    var steps: [Step]
    /// pending, done, cancelled, or failed.
    var outcome: String
    var detail: String?

    init(steps: [Step], outcome: String, detail: String? = nil) {
        self.steps = steps
        self.outcome = outcome
        self.detail = detail
    }

    /// Reads a plan written into the text by older versions: `_Plan:_` followed by `_1. step · outcome_` lines, where a
    /// step can span several lines (a message body). Returns the text without the plan, or nil when there is none.
    static func legacy(in text: String) -> (text: String, plan: StoredPlan)? {
        let marker = "_Plan:_\n"
        guard let range = text.range(of: marker, options: .backwards),
              range.lowerBound == text.startIndex || text[..<range.lowerBound].hasSuffix("\n\n") else { return nil }
        var rest = Substring(text[range.upperBound...])
        var steps: [Step] = []
        var number = 1
        var cancelled = false
        while !rest.isEmpty {
            guard rest.hasPrefix("_\(number). ") else { return nil }
            rest = rest.dropFirst("_\(number). ".count)
            let entry: Substring
            if let next = rest.range(of: "_\n_\(number + 1). ") {
                entry = rest[..<next.lowerBound]
                rest = rest[rest.index(after: next.lowerBound)...].dropFirst()
            } else {
                guard rest.hasSuffix("_") else { return nil }
                entry = rest.dropLast()
                rest = ""
            }
            // The first " · " followed by an outcome: a step or its result can hold the separator too.
            var search = entry.startIndex..<entry.endIndex
            var parsed: (summary: String, line: String, state: ActionStepState, included: Bool)?
            while parsed == nil, let split = entry.range(of: " · ", range: search) {
                let line = String(entry[split.upperBound...])
                if let outcome = legacyState(line) {
                    parsed = (String(entry[..<split.lowerBound]), line, outcome.0, outcome.1)
                }
                search = split.upperBound..<entry.endIndex
            }
            guard let parsed else { return nil }
            if parsed.line == "cancelled" { cancelled = true }
            steps.append(Step(tool: "", summary: parsed.summary, input: nil, state: parsed.state, included: parsed.included))
            number += 1
        }
        guard !steps.isEmpty else { return nil }
        let outcome: String
        if steps.contains(where: { if case .failed = $0.state { return true }; return false }) {
            outcome = "failed"
        } else if cancelled {
            outcome = "cancelled"
        } else if steps.contains(where: { $0.state.isFinished && $0.state != .skipped }) {
            outcome = "done"
        } else {
            outcome = "pending"
        }
        var body = String(text[..<range.lowerBound])
        while body.hasSuffix("\n") { body.removeLast() }
        return (body, StoredPlan(steps: steps, outcome: outcome))
    }

    /// A step's outcome as older versions wrote it, and whether the step was included; nil when it is no outcome.
    private static func legacyState(_ line: String) -> (ActionStepState, Bool)? {
        if line.hasPrefix("✓✓ ") { return (.verified(String(line.dropFirst(3))), true) }
        if line.hasPrefix("✓ ") { return (.done(String(line.dropFirst(2))), true) }
        if line.hasPrefix("✗ failed: ") { return (.failed(String(line.dropFirst("✗ failed: ".count))), true) }
        if line.hasPrefix("already completed on ") { return (.duplicate(String(line.dropFirst("already completed on ".count))), true) }
        switch line {
        case "skipped": return (.skipped, false)
        case "cancelled", "not executed": return (.pending, true)
        default: return nil
        }
    }
}
