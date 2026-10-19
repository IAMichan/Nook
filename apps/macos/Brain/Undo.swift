import Foundation

/// "Maak ongedaan": what reverses an action Nook just carried out. Nook
/// undoes what it did in your calendar, reminders and to-dos, as a plan you approve like any other (tested in UndoTests).
enum Undo {
    struct Step: Equatable {
        var tool: String
        var input: [String: String]
    }

    /// The step that reverses one executed action, from its tool, input and the result the service gave. Nil when it
    /// cannot be undone (a sent mail or message, a changed event whose old values are gone).
    static func step(tool: String, input: [String: Any], result: String) -> Step? {
        switch tool {
        case "create_event":
            return createdID(in: result).map { Step(tool: "delete_event", input: titled(["id": $0], input)) }
        case "create_reminder":
            return createdID(in: result).map { Step(tool: "delete_reminder", input: titled(["id": $0], input)) }
        case "add_open_loop":
            return bracketID(in: result).map { Step(tool: "complete_open_loop", input: ["loop": $0]) }
        case "complete_reminder":
            return nil
        default:
            return nil
        }
    }

    /// The title the action was made with, so the plan says what goes ("Remove from calendar: Lunch").
    private static func titled(_ input: [String: String], _ original: [String: Any]) -> [String: String] {
        guard let title = original["title"] as? String, !title.isEmpty else { return input }
        return input.merging(["title": title]) { old, _ in old }
    }

    /// "(id ABC-123)" in a result.
    static func createdID(in result: String) -> String? {
        guard let range = result.range(of: #"\(id ([^)\s]+)\)"#, options: .regularExpression) else { return nil }
        let id = result[range].dropFirst(4).dropLast()
        return id.isEmpty ? nil : String(id)
    }

    /// "[id 1a2b3c4d]" in a result.
    static func bracketID(in result: String) -> String? {
        guard let range = result.range(of: #"\[id ([^\]\s]+)\]"#, options: .regularExpression) else { return nil }
        let id = result[range].dropFirst(4).dropLast()
        return id.isEmpty ? nil : String(id)
    }

    /// The user asks to undo what was just done (Dutch, English, German).
    static func isRequest(_ raw: String) -> Bool {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard text.split(separator: " ").count <= 8 else { return false }
        let pattern = #"^((nook|hé nook|hey nook)[ ,]+)?((maak|zet) (dat|dit|het|alles|die|deze)? ?(maar )?(weer )?ongedaan|ongedaan maken|draai (dat|dit|het) (maar )?(weer )?terug|terugdraaien|undo( (that|it|this))?|revert( (that|it))?|cancel (that|it)|mach (das|es) rückgängig|rückgängig( machen)?|doe (dat|het) maar niet|toch niet|annule( (ça|ca|cela))?|annuler( (ça|ca|cela))?|deshaz( eso)?|deshacer( eso)?)( alsjeblieft| please| bitte| stp| por favor)?$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// The actions to undo: those of the most recent batch (done within two minutes of the last one), at most half an
    /// hour ago, newest first.
    static func batch<T>(_ actions: [(item: T, date: Date)], now: Date = Date()) -> [T] {
        guard let last = actions.map(\.date).max(), now.timeIntervalSince(last) <= 1_800 else { return [] }
        return actions.filter { last.timeIntervalSince($0.date) <= 120 }.sorted { $0.date > $1.date }.map(\.item)
    }
}
