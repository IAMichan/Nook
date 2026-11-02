import Foundation

/// A prompt an agent's own app draws and waits on, which no hook can answer: the Claude app's "Allow Claude to use
/// Nook?" before its computer-use tools work on your screen (`request_access`, `request_full_control`). The app asks it
/// inside the tool call, after the hooks have run, so a hook reply cannot allow or deny it. Nook shows the same question
/// as an approval card, and when you decide there it presses the app's own button for you (`AppPromptPresser`).
enum AppPrompt {
    enum Answer: Equatable { case allow, deny }

    /// The agents whose app draws such a prompt in its own window, with that app's bundle identifier. Only the Claude
    /// app has computer-use tools that ask this way; agents in a terminal ask in text, which their hooks already answer
    /// (see docs/INTEGRATIONS.md).
    static let hosts: [String: String] = ["claude-desktop": "com.anthropic.claudefordesktop"]

    /// The apps to look for the prompt in, best guess first: empty when this tool asks nothing, or when the agent's app
    /// has no buttons Nook can press.
    static func hostBundleIDs(agentID: String, hostBundleID: String, tool: String) -> [String] {
        guard let action = ScreenAction(tool: tool), action.asksYou, let known = hosts[agentID] else { return [] }
        return hostBundleID.isEmpty || hostBundleID == known ? [known] : [known, hostBundleID]
    }

    /// The card's title, in the words of the app's own prompt.
    static func title(tool: String, agent: String) -> String {
        ScreenAction(tool: tool) == .requestFullControl
            ? tr("ws.approval.screenControl", agent)
            : tr("ws.approval.screenApps", agent)
    }

    /// The apps the agent asks for and why, as the card shows them; every argument when the tool names neither.
    static func summary(input: [String: Any]) -> String {
        let apps = appNames(input["apps"] ?? input["applications"])
        let reason = ((input["reason"] as? String) ?? (input["justification"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = [apps.joined(separator: ", "), reason].filter { !$0.isEmpty }
        return lines.isEmpty ? McpToolName.arguments(input) : lines.joined(separator: "\n")
    }

    /// App names from a list of names or of objects that carry one.
    static func appNames(_ value: Any?) -> [String] {
        guard let list = value as? [Any] else { return (value as? String).map { [$0] } ?? [] }
        return list.compactMap { item in
            if let name = item as? String { return name }
            guard let object = item as? [String: Any] else { return nil }
            for key in ["displayName", "display_name", "name", "app", "bundleId", "bundle_id"] {
                if let name = object[key] as? String, !name.isEmpty { return name }
            }
            return nil
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    // MARK: Which button

    /// Words on a button that turns the agent down, in the languages the app may run in. Checked before the allow words,
    /// so "Don't allow" and "Niet toestaan" deny.
    private static let denyWords = [
        "deny", "don't allow", "don’t allow", "do not allow", "decline", "reject",
        "weigeren", "niet toestaan", "afwijzen",
        "ablehnen", "nicht erlauben", "nicht zulassen", "verweigern",
        "refuser", "ne pas autoriser",
        "denegar", "no permitir", "rechazar"
    ]
    private static let allowWords = ["allow", "toestaan", "sta toe", "erlauben", "zulassen", "autoriser", "permitir"]
    /// "Allow for this session": the allow button the prompt shows first, preferred when there are more.
    private static let sessionWords = ["session", "sessie", "sitzung", "séance", "sesión", "sesion"]

    /// Which of the buttons in one window of the app answers the prompt. Nil unless Nook can tell for sure: the window
    /// shows both an allow and a deny button (so the prompt is on screen), and only one button can be the answer. Nook
    /// never presses a button it is unsure of; it opens the app instead.
    static func button(_ answer: Answer, among labels: [String]) -> Int? {
        let kinds = labels.map(kind)
        let allows = kinds.indices.filter { kinds[$0] == .allow }
        let denies = kinds.indices.filter { kinds[$0] == .deny }
        guard !allows.isEmpty, !denies.isEmpty else { return nil }
        switch answer {
        case .deny:
            return denies.count == 1 ? denies[0] : nil
        case .allow:
            if allows.count == 1 { return allows[0] }
            let session = allows.filter { index in sessionWords.contains { normalized(labels[index]).contains($0) } }
            return session.count == 1 ? session[0] : nil
        }
    }

    private static func kind(_ label: String) -> Answer? {
        let text = normalized(label)
        guard !text.isEmpty, text.count <= 60 else { return nil }
        if denyWords.contains(where: { starts(text, with: $0) }) { return .deny }
        if allowWords.contains(where: { starts(text, with: $0) }) { return .allow }
        return nil
    }

    /// The label starts with the word: "Allow for this session ⌘↩" is an allow button, a sentence that only mentions
    /// allowing somewhere ("Claude will work in these apps …") is not a button to press.
    private static func starts(_ text: String, with word: String) -> Bool {
        guard text.hasPrefix(word) else { return false }
        let rest = text.dropFirst(word.count)
        return rest.first.map { !$0.isLetter } ?? true
    }

    /// Lowercased, with the shortcut glyphs and spacing the app puts beside the words trimmed off.
    static func normalized(_ label: String) -> String {
        label.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.letters.inverted)
    }
}
