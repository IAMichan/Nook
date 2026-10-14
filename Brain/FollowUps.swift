import Foundation

/// Vervolgvoorstellen: het brein zet onder een antwoord hooguit twee regels die met "»" beginnen,
/// geschreven als wat jij tegen Nook zou zeggen ("» Zet het in mijn agenda"). Nook haalt ze uit de tekst
/// en toont ze als knoppen; een klik stuurt de zin als nieuw verzoek.
enum FollowUps {
    static let marker = "»"

    /// De tekst zonder voorstellen, en de voorstellen zelf (hooguit twee, zonder dubbele).
    static func split(_ text: String) -> (body: String, offers: [String]) {
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
        return (cleaned, Array(offers.prefix(2)))
    }

    /// Tijdens het streamen: alleen de tekst, ook als een voorstel nog half binnen is ("»" zonder rest, of ">" van ">>").
    static func streamingBody(_ text: String) -> String {
        var body = split(text).body
        if let last = body.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces), last == ">" || last == "-" {
            body = String(body.dropLast(last.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    /// Algemene aanbiedingen die niets toevoegen ("Vertel meer", "Nog iets?"), laat Nook weg.
    private static func isGeneric(_ offer: String) -> Bool {
        let pattern = #"^(vertel (me )?meer|meer (info|informatie|details)|nog iets( anders)?|iets anders|leg (het|dat) uit|ga door|ga verder|help me( verder)?|kun je meer|wat nog meer|tell me more|anything else)\W*$"#
        return offer.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func offerText(_ line: String) -> Substring? {
        if line.hasPrefix(marker) { return line.dropFirst(marker.count) }
        if line.hasPrefix(">>") { return line.dropFirst(2) }
        return nil
    }
}
