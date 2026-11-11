import Foundation

/// Follow-up suggestions: the brain puts at most three lines starting with "»" below an answer,
/// phrased as what you would say to Nook ("» Add this to my calendar", "» Compare it with last month"). Nook extracts
/// them from the text and renders them as buttons; clicking one sends the prompt as a new request, so a conversation
/// can go on with one click. Tested in `FollowUpsTests`.
enum FollowUps {
    static let marker = "»"
    /// Offers the chat shows under an answer; a card in the notch has room for `cardLimit`.
    static let limit = 3
    static let cardLimit = 2

    /// The text body without suggestions, and the suggestions themselves (at most `limit`, deduplicated).
    static func split(_ text: String, limit: Int = FollowUps.limit) -> (body: String, offers: [String]) {
        var body: [Substring] = []
        var offers: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let rest = offerText(trimmed) else {
                body.append(line)
                continue
            }
            let offer = rest.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_\"“”")))
            if !offer.isEmpty, offer.count <= 72, !isGeneric(offer), !offers.contains(where: { $0.caseInsensitiveCompare(offer) == .orderedSame }) {
                offers.append(offer)
            }
        }
        let cleaned = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, Array(offers.prefix(max(limit, 0))))
    }

    /// While streaming: text body only, even when a suggestion is only partially streamed ("»" with no text, or ">" from ">>").
    static func streamingBody(_ text: String) -> String {
        var body = split(text).body
        if let last = body.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces), last == ">" || last == "-" || last == "*" {
            body = String(body.dropLast(last.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    /// Generic suggestions that add no value ("Tell me more", "Anything else?") are filtered out.
    private static func isGeneric(_ offer: String) -> Bool {
        let pattern = #"^(vertel (me )?meer|meer (info|informatie|details)|nog iets( anders)?|iets anders|leg (het|dat) uit|ga door|ga verder|help me( verder)?|kun je meer|wat nog meer|tell me more|anything else|erzähl (mir )?mehr|mehr details|dis[- ]m'en plus|autre chose|cuéntame más|algo más)\W*$"#
        return offer.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func offerText(_ line: String) -> Substring? {
        // A model that writes its offers as a list ("- » …", "* » …", "1. » …") still means an offer.
        var line = Substring(line)
        if let bullet = line.firstIndex(where: { !"-*•0123456789.) ".contains($0) }), bullet != line.startIndex,
           line[bullet...].hasPrefix(marker) {
            line = line[bullet...]
        }
        if line.hasPrefix(marker) { return line.dropFirst(marker.count) }
        if line.hasPrefix(">>") { return line.dropFirst(2) }
        return nil
    }
}
