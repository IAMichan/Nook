import Foundation

/// Korte, vaste opdrachten ("volgende nummer", "volume 30", "open Safari") herkent Nook zelf,
/// zonder het brein: dat is meteen klaar en kost niets. Alles wat niet precies past, gaat gewoon naar het brein.
enum LocalIntent: Equatable {
    case media(String)          // play_pause, next, previous
    case volume(Int)
    case volumeStep(Int)        // +10 of -10
    case openApp(String)
    case showTab(PanelTab)
    case weekRecap
    case time

    static func parse(_ raw: String) -> LocalIntent? {
        let text = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: "  ", with: " ")
        guard !text.isEmpty, text.split(separator: " ").count <= 7 else { return nil }
        let polite = text
            .replacingOccurrences(of: #"^(nook|hé nook|hey nook)[ ,]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(wil je|kun je|kan je|graag|please)\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(alsjeblieft|aub|graag|please)$"#, with: "", options: .regularExpression)

        func matches(_ pattern: String) -> Bool {
            polite.range(of: "^(" + pattern + ")$", options: .regularExpression) != nil
        }

        if matches(#"(volgend[e]?|het volgende) ?(nummer|liedje|track)?|next( song| track)?|skip( dit)?( nummer)?"#) {
            return .media("next")
        }
        if matches(#"(vorig[e]?|het vorige) ?(nummer|liedje|track)?|previous( song| track)?"#) {
            return .media("previous")
        }
        if matches(#"pauze|pauzeer|pauzeer (de )?muziek|stop (de )?muziek|muziek (uit|stop)|pause( music)?|play|speel( verder| af)?|hervat|resume|muziek aan"#) {
            return .media("play_pause")
        }
        if let level = number(in: polite, pattern: #"^(zet )?(het )?(volume|geluid)( op| naar)? (\d{1,3})( ?%| procent)?$"#) {
            return .volume(min(100, level))
        }
        if let level = number(in: polite, pattern: #"^(set )?volume( to)? (\d{1,3})( ?%| percent)?$"#) {
            return .volume(min(100, level))
        }
        if matches(#"harder|luider|volume (omhoog|hoger)|louder|volume up"#) { return .volumeStep(10) }
        if matches(#"zachter|stiller|volume (omlaag|lager)|quieter|volume down"#) { return .volumeStep(-10) }
        if matches(#"(laat )?(mijn |de )?(agents|agenten)( zien| tab)?|(show )?agents"#) { return .showTab(.agents) }
        if matches(#"(open |toon )?(vandaag|today|nook|home|startpagina)"#) { return .showTab(.nook) }
        if matches(#"(open |toon )?(de )?chat"#) { return .showTab(.chat) }
        if matches(#"(open |toon )?(mijn |de )?(koppelingen|diensten|integraties|connections)( tab)?"#) { return .showTab(.connect) }
        if matches(#"(open |toon )?(de )?(muziek|music)( tab)?"#) { return .showTab(.music) }
        if matches(#"(mijn |het )?(weekoverzicht|week ?recap|weekrecap|weekly recap)|hoe was mijn week"#) { return .weekRecap }
        if matches(#"hoe laat is het|what time is it|tijd"#) { return .time }

        if let range = polite.range(of: #"^(open|start)\s+"#, options: .regularExpression) {
            let name = String(polite[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let app = installedApp(named: name) { return .openApp(app) }
        }
        return nil
    }

    private static func number(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        for index in stride(from: match.numberOfRanges - 1, through: 1, by: -1) {
            if let range = Range(match.range(at: index), in: text), let value = Int(text[range]) { return value }
        }
        return nil
    }

    /// Alleen apps die echt bestaan; "open de mail van Lisa" valt zo vanzelf door naar het brein.
    private static func installedApp(named name: String) -> String? {
        guard !name.isEmpty, name.split(separator: " ").count <= 3, !name.contains("/") else { return nil }
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        for folder in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            if let hit = items.first(where: { $0.lowercased() == name + ".app" }) {
                return String(hit.dropLast(4))
            }
        }
        return nil
    }
}
