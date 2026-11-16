import Foundation

/// Whether the user asked a session for a pull request themselves ("make a commit and PR"). Then `pull_request_create`
/// opens it without a second approval: the user already decided. A pull request the agent proposes on its own still
/// asks. Nook reads this from the user's own messages in the session, never from what the agent says about it.
enum PullRequestAsked {
    /// The user's messages since the conversation last showed a pull request (or since the start): one of them asks for
    /// a new one. A request that was already answered with a pull request does not allow the next one. `delegated`: the
    /// session's first message is the brief of the agent that started it, not the user's words.
    static func asked(in events: [RunEvent], delegated: Bool = false) -> Bool {
        let firstUser = delegated ? events.first(where: { $0.kind == .user })?.id : nil
        for event in events.reversed() {
            if RunPullRequestLinks.pullRequest(in: event) != nil { return false }
            guard event.kind == .user, event.rolledBack != true, event.id != firstUser, !fromAgent(event.text) else { continue }
            if asks(event.text) { return true }
        }
        return false
    }

    /// A message another agent sent with `session_send` (framed that way in `WorkspaceBridge.sessionSend`).
    static func fromAgent(_ text: String) -> Bool {
        text.hasPrefix("Message from ") && text.contains("(another agent, not the user")
    }

    /// One message asks for a pull request: a sentence that names one, says what to do with it (make, open, commit…)
    /// and does not say not to ("no PR yet"). A question asks only with a word that makes one ("can you make a PR?"):
    /// "is the PR still open?" asks about one that exists.
    static func asks(_ message: String) -> Bool {
        sentences(message).contains { sentence, question in
            let words = Self.words(sentence)
            guard names(words, sentence) else { return false }
            guard !words.contains(where: negations.contains) else { return false }
            return words.contains { actions.contains($0) && !(question && aboutOne.contains($0)) }
        }
    }

    /// The message's sentences, each with whether it ends in a question mark.
    private static func sentences(_ text: String) -> [(text: String, question: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        for character in text.lowercased() {
            if ".!?\n;".contains(character) {
                if !current.isEmpty { result.append((current, character == "?")) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append((current, false)) }
        return result
    }

    private static func words(_ sentence: String) -> [String] {
        sentence.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func names(_ words: [String], _ sentence: String) -> Bool {
        if words.contains(where: ["pr", "prs", "pullrequest", "mr"].contains) { return true }
        return ["pull request", "pull-request", "merge request", "merge-request"].contains { sentence.contains($0) }
    }

    /// Words that say not to: "no PR", "geen PR", "keinen PR", "pas de PR", "sin PR".
    private static let negations: Set<String> = [
        "no", "not", "don", "dont", "never", "without",
        "geen", "niet", "nooit", "zonder",
        "kein", "keine", "keinen", "nicht", "nie", "ohne",
        "pas", "ne", "sans", "jamais",
        "sin", "nunca",
    ]

    /// Words that ask for one: "make", "open", "commit" ("commit and PR"), "please" ("PR please").
    private static let actions: Set<String> = [
        "make", "create", "file", "submit", "raise", "send", "push", "put", "commit", "ship", "please",
        "maak", "maken", "aanmaken", "open", "openen", "indienen", "zet", "stuur", "doe", "graag", "aub",
        "mach", "mache", "erstelle", "erstellen", "öffne", "öffnen", "eröffne", "schick", "bitte",
        "fais", "faire", "crée", "créer", "ouvre", "ouvrir", "envoie", "stp", "svp",
        "haz", "hacer", "crea", "crear", "abre", "abrir", "envía", "envia", "favor",
    ]

    /// Action words that also describe a pull request that exists ("is it open?", "did you push it?"): in a question
    /// they do not ask for a new one.
    private static let aboutOne: Set<String> = [
        "open", "openen", "push", "commit", "send", "stuur", "ship", "put", "file", "zet", "doe",
        "öffne", "öffnen", "schick", "ouvre", "ouvrir", "envoie", "abre", "abrir", "envía", "envia",
    ]
}
