import Foundation

/// Where on Nook an accessory sits. He wears at most one per place.
enum NookAccessorySlot: String, CaseIterable, Codable {
    case head, eyes, neck
}

/// Something Nook can wear. Drawn by `NookAccessoryLayer`; chosen in Settings › Appearance › Wardrobe, or put on by
/// itself for the season, the time of day or a moment (`NookOutfit.resolve`).
enum NookAccessory: String, CaseIterable, Codable, Identifiable {
    case beanie, nightcap, partyHat, crown, hardHat, beret, santaHat
    case roundGlasses, sunglasses
    case scarf

    var id: String { rawValue }

    var slot: NookAccessorySlot {
        switch self {
        case .beanie, .nightcap, .partyHat, .crown, .hardHat, .beret, .santaHat: return .head
        case .roundGlasses, .sunglasses: return .eyes
        case .scarf: return .neck
        }
    }

    /// Text key of its name in Settings.
    var titleKey: String { "wardrobe.item.\(rawValue)" }
}

/// What Nook wears, chosen in Settings: one item per place, and whether he may dress himself for the season, the
/// time of day and the moments he shares with you. A chosen item always wins over one he would pick himself.
struct NookWardrobe: Codable, Equatable {
    /// Nook dresses himself where nothing is chosen: a scarf in winter, a nightcap late at night, a party hat when
    /// there is something to celebrate.
    var automatic: Bool
    /// At most one per slot; the stored order is the order they were picked in.
    var chosen: [NookAccessory]

    static let standard = NookWardrobe(automatic: true, chosen: [])

    init(automatic: Bool, chosen: [NookAccessory]) {
        self.automatic = automatic
        self.chosen = []
        for item in chosen { wear(item) }
    }

    /// What Nook wears in this place, by your choice.
    func chosen(in slot: NookAccessorySlot) -> NookAccessory? {
        chosen.first { $0.slot == slot }
    }

    /// Puts the item on, replacing whatever was chosen for its place.
    mutating func wear(_ item: NookAccessory) {
        chosen.removeAll { $0.slot == item.slot }
        chosen.append(item)
    }

    /// Takes off what was chosen for this place, so Nook may pick for it again (when `automatic`).
    mutating func clear(_ slot: NookAccessorySlot) {
        chosen.removeAll { $0.slot == slot }
    }

    /// The stored form: JSON. Unreadable input gives the standard wardrobe; an item from a later version is skipped.
    var stored: String {
        let object: [String: Any] = ["automatic": automatic, "chosen": chosen.map(\.rawValue)]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(stored: String?) {
        self = .standard
        guard let data = stored?.data(using: .utf8),
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if let automatic = fields["automatic"] as? Bool { self.automatic = automatic }
        if let raw = fields["chosen"] as? [String] {
            chosen = []
            for item in raw.compactMap(NookAccessory.init(rawValue:)) { wear(item) }
        }
    }
}

/// A day of the year as month and day, for a birthday. Stored as "MM-dd".
struct NookMonthDay: Equatable, Codable {
    var month: Int
    var day: Int

    init?(month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        self.month = month
        self.day = day
    }

    init?(stored: String?) {
        let parts = (stored ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(month: parts[0], day: parts[1])
    }

    var stored: String { String(format: "%02d-%02d", month, day) }

    func matches(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        // Born on 29 February: celebrated on the 28th in other years.
        if month == 2, day == 29, parts.month == 2, parts.day == 28,
           let year = calendar.dateComponents([.year], from: date).year, !Self.isLeap(year) { return true }
        return parts.month == month && parts.day == day
    }

    private static func isLeap(_ year: Int) -> Bool { (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 }
}

/// What Nook wears right now. Pure, so it can be tested: everything it depends on comes in through `Context`.
enum NookOutfit {
    struct Context {
        var date: Date
        var calendar: Calendar = .current
        /// Seasons are the other way around below the equator.
        var southernHemisphere = false
        /// The country of the Mac's region ("NL"), for national holidays.
        var region: String?
        var birthday: NookMonthDay?
        /// A moment worth a party: a release, a milestone, the last agent finishing.
        var celebrating = false
        /// You are in a focus block.
        var focusing = false
        /// Headphones are on (music plays): hats would clash with the band, so his head stays free.
        var headphones = false
    }

    /// Everything Nook wears, at most one item per slot, head first.
    static func resolve(_ wardrobe: NookWardrobe, context: Context) -> [NookAccessory] {
        var outfit: [NookAccessory] = []
        for slot in NookAccessorySlot.allCases {
            if slot == .head, context.headphones { continue }
            if let item = wardrobe.chosen(in: slot) ?? (wardrobe.automatic ? automatic(slot, context: context) : nil) {
                outfit.append(item)
            }
        }
        return outfit
    }

    /// What Nook picks himself for one place, or nil to leave it free.
    static func automatic(_ slot: NookAccessorySlot, context c: Context) -> NookAccessory? {
        let parts = c.calendar.dateComponents([.month, .day, .hour, .weekday], from: c.date)
        let month = parts.month ?? 1, day = parts.day ?? 1, hour = parts.hour ?? 12
        let winter = c.southernHemisphere ? (6...8).contains(month) : (month == 12 || month <= 2)
        let summer = c.southernHemisphere ? (month == 12 || month <= 2) : (7...8).contains(month)
        let weekend = parts.weekday == 1 || parts.weekday == 7

        switch slot {
        case .head:
            if c.celebrating { return .partyHat }
            if let birthday = c.birthday, birthday.matches(c.date, calendar: c.calendar) { return .partyHat }
            if month == 12, day == 31, hour >= 20 { return .partyHat }
            if month == 1, day == 1, hour < 4 { return .partyHat }
            if lateNight(hour) { return .nightcap }
            if month == 12, (24...26).contains(day) { return .santaHat }
            if c.region == "NL", month == 4, day == 27 { return .crown }
            if winter, hour >= 7, hour < 11 { return .beanie }
            return nil
        case .eyes:
            if c.focusing { return .roundGlasses }
            if summer, weekend, (11..<18).contains(hour) { return .sunglasses }
            return nil
        case .neck:
            return winter ? .scarf : nil
        }
    }

    /// Between 23:00 and 05:00.
    static func lateNight(_ hour: Int) -> Bool { hour >= 23 || hour < 5 }

    /// Regions south of the equator, where December is summer.
    static let southernRegions: Set<String> = ["AU", "NZ", "ZA", "AR", "CL", "UY", "PY", "BR", "PE", "BO", "NA", "BW", "MZ", "ZW",
                                               "MG", "MU", "FJ", "LS", "SZ"]
}
