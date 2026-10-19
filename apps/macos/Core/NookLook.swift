import Foundation

/// How Nook's eyes are drawn.
enum NookEyeStyle: String, CaseIterable, Codable, Identifiable {
    /// Round, glossy eyes with two catchlights.
    case round
    /// The original tall capsules.
    case bars
    /// Small solid dots: the most minimal face.
    case dots

    var id: String { rawValue }
}

/// Whether Nook has a mouth, and how much it moves.
enum NookMouthStyle: String, CaseIterable, Codable, Identifiable {
    /// Opens, smiles and frowns with each mood, and moves along while Nook reads an answer aloud.
    case expressive
    /// A single line that only smiles or frowns.
    case line
    case none

    var id: String { rawValue }
}

/// Nook's appearance, chosen in Settings › Appearance. Its color is the app's accent color, set separately.
struct NookLook: Codable, Equatable {
    var eyes: NookEyeStyle
    var mouth: NookMouthStyle
    /// Lit like a ball (highlight, shade, bounce light) instead of a flat disc.
    var gloss: Bool
    /// The soft light around the orb, outside the notch.
    var glow: Bool
    /// Blushes when petted or tickled.
    var cheeks: Bool

    static let minimal = NookLook(eyes: .dots, mouth: .none, gloss: false, glow: false, cheeks: false)
    /// The look Nook always had; the default, so nothing changes until someone picks another one.
    static let classic = NookLook(eyes: .bars, mouth: .none, gloss: true, glow: true, cheeks: true)
    static let playful = NookLook(eyes: .round, mouth: .expressive, gloss: true, glow: true, cheeks: true)

    static let presets = [
        NookLookPreset(id: "minimal", look: .minimal),
        NookLookPreset(id: "classic", look: .classic),
        NookLookPreset(id: "playful", look: .playful)
    ]

    /// The stored form: JSON. Anything unreadable falls back to the classic look; an unknown value for one option
    /// (a style added in a later version) keeps the others.
    var stored: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(eyes: NookEyeStyle, mouth: NookMouthStyle, gloss: Bool, glow: Bool, cheeks: Bool) {
        self.eyes = eyes
        self.mouth = mouth
        self.gloss = gloss
        self.glow = glow
        self.cheeks = cheeks
    }

    init(stored: String?) {
        self = .classic
        guard let data = stored?.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let raw = fields["eyes"] as? String, let eyes = NookEyeStyle(rawValue: raw) { self.eyes = eyes }
        if let raw = fields["mouth"] as? String, let mouth = NookMouthStyle(rawValue: raw) { self.mouth = mouth }
        if let gloss = fields["gloss"] as? Bool { self.gloss = gloss }
        if let glow = fields["glow"] as? Bool { self.glow = glow }
        if let cheeks = fields["cheeks"] as? Bool { self.cheeks = cheeks }
    }
}

/// A ready-made look, offered as a starting point in Settings.
struct NookLookPreset: Identifiable {
    let id: String
    let look: NookLook
}

/// A mouth shape while Nook speaks, picked from the letter being said. Sizes are fractions of the orb.
enum NookViseme: Equatable {
    case open       // a
    case wide       // e
    case narrow     // i, y, j
    case round      // o
    case pursed     // u, w
    case closed     // m, b, p
    case teeth      // f, v
    case consonant  // any other letter
    case rest       // spaces, punctuation, digits

    init(_ character: Character) {
        switch character.lowercased().first ?? " " {
        case "a", "á", "à", "â", "ä": self = .open
        case "e", "é", "è", "ê", "ë": self = .wide
        case "i", "í", "ï", "y", "j": self = .narrow
        case "o", "ó", "ô", "ö": self = .round
        case "u", "ú", "ü", "w": self = .pursed
        case "m", "b", "p": self = .closed
        case "f", "v": self = .teeth
        case let c where c.isLetter: self = .consonant
        default: self = .rest
        }
    }

    /// Width and opening of the mouth, and how round it is (0 = lips, 1 = an "o").
    var shape: (width: Double, open: Double, round: Double) {
        switch self {
        case .open: return (0.19, 0.14, 0.2)
        case .wide: return (0.22, 0.08, 0)
        case .narrow: return (0.23, 0.045, 0)
        case .round: return (0.12, 0.12, 1)
        case .pursed: return (0.08, 0.07, 1)
        case .closed: return (0.16, 0, 0)
        case .teeth: return (0.17, 0.03, 0)
        case .consonant: return (0.17, 0.055, 0.1)
        case .rest: return (0.15, 0, 0)
        }
    }

    /// The shape for a word that started `elapsed` seconds ago, spoken at about 14 letters a second; nil once it is said.
    static func during(_ word: String, elapsed: TimeInterval, lettersPerSecond: Double = 14) -> NookViseme? {
        guard elapsed >= 0 else { return nil }
        let letters = Array(word)
        let index = Int(elapsed * lettersPerSecond)
        return index < letters.count ? NookViseme(letters[index]) : nil
    }
}
