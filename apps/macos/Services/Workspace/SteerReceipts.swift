import Foundation

/// Whether an agent read a steer yet it ("Steer · waiting to be read"). An agent that steers natively
/// takes a steered message in between steps, after a running tool returns, so it can sit unread for a while. Agents that
/// echo a message of yours when they read it (`ProviderCapabilities.echoesSteers`: Pi's user `message_start`, a Codex
/// app-server `userMessage` item) mark the steer `pending` until that echo; Stop drops an unread one (`cancelled`).
enum SteerReceipts {
    /// The steer an agent's echo of a message of yours stands for: the oldest waiting one with the same words, else the
    /// oldest waiting one, unless the echo is the turn's own prompt (Pi and Codex echo that one too). Nil when none waits.
    /// `echo` is the text the agent echoed, nil when it gave none.
    static func read(in events: [RunEvent], echo: String?, turnPrompt: String?) -> UUID? {
        let waiting = events.filter { $0.kind == .user && $0.steerStatus == .pending }
        guard let oldest = waiting.first else { return nil }
        guard let echo = echo.map(normalized), !echo.isEmpty else { return oldest.id }
        if let same = waiting.first(where: { event in
            let words = normalized(event.text)
            return !words.isEmpty && (words == echo || echo.contains(words))
        }) {
            return same.id
        }
        if let prompt = turnPrompt.map(normalized), !prompt.isEmpty, echo == prompt || echo.contains(prompt) { return nil }
        return oldest.id
    }

    /// The steers still waiting when a turn ends: a stopped or failed turn dropped them unread, a completed one read
    /// them (the agent takes queued steers in before it settles). What each becomes, by event id.
    static func settled(_ events: [RunEvent], dropped: Bool) -> [(id: UUID, status: RunEvent.SteerStatus?)] {
        events.filter { $0.kind == .user && $0.steerStatus == .pending }.map { ($0.id, dropped ? .cancelled : nil) }
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
