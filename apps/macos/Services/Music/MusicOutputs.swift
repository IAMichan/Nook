import Foundation

/// Where the music sounds: a speaker or headphones of this Mac, an AirPlay device Music sends to, or a Spotify Connect
/// device (a phone, a speaker, a TV). The Music pages show the one in use and let the user pick another
/// (`MusicOutputService`). Everything here is pure, so the tests read the players' answers without a Mac.
struct MusicOutput: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case speaker, headphones, bluetooth, display, airPlay, phone, computer, tv, car, other
    }

    /// How Nook sends the sound there.
    enum Route: Equatable, Hashable, Sendable {
        /// An output device of this Mac (a Core Audio device id): the system's sound output.
        case mac(UInt32)
        /// One of Music's AirPlay devices, by its name.
        case airPlay(String)
        /// A Spotify Connect device, by its id.
        case spotify(String)
    }

    var route: Route
    var name: String
    var kind: Kind
    /// The sound goes here now.
    var active: Bool
    /// The device's own volume, 0–100, when it says.
    var volume: Int? = nil

    var id: String {
        switch route {
        case .mac(let device): return "mac:\(device)"
        case .airPlay(let name): return "airplay:\(name)"
        case .spotify(let device): return "spotify:\(device)"
        }
    }

    /// The SF Symbol name of the kind (`Image(icon:)` turns it into Nook's own icon).
    var symbol: String {
        switch kind {
        case .speaker: return "speaker.wave.2"
        case .headphones, .bluetooth: return "headphones"
        case .display, .tv: return "display"
        case .airPlay: return "dot.radiowaves.left.and.right"
        case .phone: return "iphone"
        case .computer: return "laptopcomputer"
        case .car: return "car"
        case .other: return "speaker.wave.2"
        }
    }

    /// On this Mac, as opposed to somewhere else in the house.
    var isOnThisMac: Bool {
        if case .mac = route { return true }
        return false
    }
}

enum MusicOutputs {
    // MARK: This Mac (Core Audio)

    /// A Core Audio four-character code ("bltn") as the number Core Audio uses.
    static func fourCC(_ text: String) -> UInt32 {
        text.utf8.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static let builtIn = fourCC("bltn")
    static let bluetooth = fourCC("blue")
    static let bluetoothLE = fourCC("blea")
    static let usb = fourCC("usb ")
    static let hdmi = fourCC("hdmi")
    static let displayPort = fourCC("dprt")
    static let airPlay = fourCC("airp")
    static let virtual = fourCC("virt")
    static let aggregate = fourCC("grup")
    static let thunderbolt = fourCC("thun")

    /// What a Mac output is, from its transport and name: the name tells headphones from a speaker.
    static func macKind(transport: UInt32, name: String) -> MusicOutput.Kind {
        let lower = name.lowercased()
        let sounds = ["headphone", "airpods", "buds", "beats", "koptelefoon", "kopfhörer", "casque", "auriculares"]
        let isHeadphones = sounds.contains { lower.contains($0) }
        switch transport {
        case builtIn: return isHeadphones ? .headphones : .speaker
        case bluetooth, bluetoothLE: return isHeadphones ? .headphones : .bluetooth
        case hdmi, displayPort: return .display
        case airPlay: return .airPlay
        default: return isHeadphones ? .headphones : .speaker
        }
    }

    /// Whether a Mac output belongs in the list. AirPlay is the players' own (Music's AirPlay devices, Spotify Connect),
    /// so it is not listed twice; the virtual devices meeting and recording apps install only when one is in use.
    static func listsMacOutput(transport: UInt32, active: Bool) -> Bool {
        if transport == airPlay { return false }
        if transport == virtual { return active }
        return true
    }

    /// The Mac's outputs in a calm order: the one in use first, then this Mac's own, then the rest by name.
    static func sorted(_ outputs: [MusicOutput]) -> [MusicOutput] {
        func rank(_ output: MusicOutput) -> Int {
            if output.active { return 0 }
            switch output.kind {
            case .speaker, .headphones: return 1
            case .bluetooth: return 2
            default: return 3
            }
        }
        return outputs.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            return left != right ? left < right : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Music (AirPlay)

    /// One record per AirPlay device Music knows: name, kind, selected, available.
    static let airPlayScript = """
    tell application "Music"
        set rs to character id 30
        set fs to character id 31
        set out to ""
        repeat with d in AirPlay devices
            set out to out & (name of d) & fs & (kind of d as text) & fs & (selected of d as text) & fs & (available of d as text) & fs & (sound volume of d as text) & rs
        end repeat
        return out
    end tell
    """

    /// Music's AirPlay devices it can send to now. "Computer" is this Mac itself, which the Mac's own outputs stand for.
    static func airPlayDevices(_ raw: String) -> [MusicOutput] {
        guard !raw.isEmpty else { return [] }
        return raw.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard fields.count >= 4, !fields[0].isEmpty, fields[0] != "missing value" else { return nil }
            let kind = airPlayKind(fields[1])
            guard kind != .computer, fields[3] == "true" else { return nil }
            let volume = fields.count >= 5 ? Int(fields[4]) : nil
            return MusicOutput(route: .airPlay(fields[0]), name: fields[0], kind: kind, active: fields[2] == "true", volume: volume)
        }
    }

    /// Music's `kind` of an AirPlay device, as AppleScript says it.
    static func airPlayKind(_ text: String) -> MusicOutput.Kind {
        switch text.lowercased() {
        case "computer": return .computer
        case "apple tv": return .tv
        case "bluetooth device": return .bluetooth
        case "homepod", "airport express", "speaker": return .speaker
        default: return .airPlay
        }
    }

    /// Sends Music to these AirPlay devices; an empty list sends it back to this Mac ("Computer").
    static func selectAirPlayScript(_ names: [String]) -> String {
        let quoted = names.map { "AirPlay device \"\(escape($0))\"" }
        let target = quoted.isEmpty ? "(every AirPlay device whose kind is computer)" : "{" + quoted.joined(separator: ", ") + "}"
        return """
        with timeout of 5 seconds
            tell application "Music" to set current AirPlay devices to \(target)
        end timeout
        """
    }

    /// A name inside an AppleScript string: quotes and backslashes escaped.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: Spotify (Connect)

    /// The devices in `GET /me/player/devices`. A restricted device cannot be controlled by another app, so it is left out.
    static func spotifyDevices(from data: Data) -> [MusicOutput] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [[String: Any]] else { return [] }
        return devices.compactMap { device in
            guard let id = device["id"] as? String, !id.isEmpty, let name = device["name"] as? String, !name.isEmpty,
                  (device["is_restricted"] as? Bool) != true else { return nil }
            return MusicOutput(route: .spotify(id), name: name, kind: spotifyKind(device["type"] as? String ?? ""),
                               active: device["is_active"] as? Bool ?? false, volume: device["volume_percent"] as? Int)
        }
    }

    /// Spotify's device `type`.
    static func spotifyKind(_ type: String) -> MusicOutput.Kind {
        switch type.lowercased() {
        case "computer": return .computer
        case "smartphone", "tablet": return .phone
        case "speaker", "avr", "audiodongle", "castaudio": return .speaker
        case "tv", "stb", "castvideo", "gameconsole": return .tv
        case "automobile": return .car
        default: return .other
        }
    }

    /// The body of `PUT /me/player`: playback moves to the device and keeps playing.
    static func spotifyTransferBody(deviceID: String) -> [String: Any] {
        ["device_ids": [deviceID], "play": true]
    }

    /// Spotify's device for this Mac: a computer by this Mac's name, or the only computer there is.
    static func spotifyThisMac(_ devices: [MusicOutput], macName: String) -> MusicOutput? {
        let computers = devices.filter { $0.kind == .computer }
        return computers.first { $0.name.caseInsensitiveCompare(macName) == .orderedSame } ?? (computers.count == 1 ? computers.first : nil)
    }

    /// The player's own devices without this Mac (the Mac's outputs stand for it).
    static func elsewhere(_ devices: [MusicOutput], macName: String) -> [MusicOutput] {
        let thisMac = spotifyThisMac(devices, macName: macName)?.id
        return devices.filter { $0.id != thisMac }
    }

    // MARK: Together

    /// Where the sound goes now: a device elsewhere the player sends to wins over the Mac's own output.
    static func current(mac: [MusicOutput], elsewhere: [MusicOutput]) -> MusicOutput? {
        elsewhere.first(where: \.active) ?? mac.first(where: \.active)
    }
}
