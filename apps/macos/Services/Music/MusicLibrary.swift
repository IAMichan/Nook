import Foundation

// Foundation-only parts of the Music tab: lyrics (LRC parsing and the LRCLIB response), and the queue, playlists and
// recent tracks the players report through AppleScript. Fetching and scripting live in `LyricsService` and
// `NowPlayingService+Library`; everything here is plain data so it can be tested without a player.

/// One line of lyrics. `time` is the second it starts at in synced lyrics, `nil` in plain ones.
struct LyricLine: Equatable, Identifiable {
    var id: Int
    var time: Double?
    var text: String
}

struct Lyrics: Equatable {
    enum Source: String, Equatable {
        /// Lyrics stored with the track in Music.
        case player
        /// lrclib.net, an open lyrics database.
        case lrclib
    }

    var lines: [LyricLine]
    var source: Source
    /// The track has no vocals.
    var instrumental = false

    /// Every line has a start time, so the current line can follow playback.
    var isSynced: Bool { !lines.isEmpty && lines.allSatisfy { $0.time != nil } }

    /// The line playing at `position` seconds: the last line that started at or before it. `nil` before the first line,
    /// or for plain lyrics.
    func activeIndex(at position: Double) -> Int? {
        guard isSynced else { return nil }
        var low = 0, high = lines.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if (lines[middle].time ?? 0) <= position {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}

enum LyricsParser {
    /// Synced lyrics in LRC format: `[mm:ss.xx] text`, several stamps per line allowed, `[offset:+/-ms]` honoured,
    /// other tags (`[ar:…]`, `[ti:…]`) skipped. Returns no lines when there is not a single time stamp.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var timed: [(time: Double, text: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let seconds = timestamp(tag) {
                    stamps.append(seconds)
                } else if tag.lowercased().hasPrefix("offset:"), let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    // A positive offset shifts the lyrics earlier.
                    offset = ms / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            let line = rest.trimmingCharacters(in: .whitespaces)
            for stamp in stamps { timed.append((stamp, line)) }
        }
        // Stable order: lines with the same time keep the order they were written in.
        let sorted = timed.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        return sorted.enumerated().map { LyricLine(id: $0.offset, time: max(0, $0.element.time - offset), text: $0.element.text) }
    }

    /// Plain lyrics: one line each, blank lines kept as stanza breaks but never more than one in a row, none at the ends.
    static func parsePlain(_ text: String) -> [LyricLine] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.enumerated().map { LyricLine(id: $0.offset, time: nil, text: $0.element) }
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss:xx` → seconds.
    static func timestamp<S: StringProtocol>(_ tag: S) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsText = parts.count == 3 ? "\(parts[1]).\(parts[2])" : String(parts[1])
        guard let seconds = Double(secondsText), seconds >= 0, seconds < 60, secondsText.first?.isNumber == true else { return nil }
        return Double(minutes) * 60 + seconds
    }

    // MARK: LRCLIB

    /// One record from lrclib.net (`/api/get` returns one, `/api/search` a list).
    struct Record: Equatable {
        var trackName: String
        var artistName: String
        var duration: Double
        var instrumental: Bool
        var plain: String?
        var synced: String?
    }

    static func records(from data: Data) -> [Record] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let list: [[String: Any]]
        if let array = object as? [[String: Any]] { list = array }
        else if let single = object as? [String: Any] { list = [single] }
        else { return [] }
        func number(_ value: Any?) -> Double {
            if let double = value as? Double { return double }
            if let int = value as? Int { return Double(int) }
            return (value as? NSNumber)?.doubleValue ?? 0
        }
        return list.compactMap { item in
            guard item["id"] != nil || item["trackName"] != nil else { return nil }
            func text(_ key: String) -> String? {
                guard let value = item[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return value
            }
            return Record(
                trackName: item["trackName"] as? String ?? "",
                artistName: item["artistName"] as? String ?? "",
                duration: number(item["duration"]),
                instrumental: (item["instrumental"] as? Bool) ?? false,
                plain: text("plainLyrics"),
                synced: text("syncedLyrics")
            )
        }
    }

    /// The best record for a track of `duration` seconds (0 when unknown): durations more than 5 seconds off are a
    /// different recording; among the rest synced lyrics win, then the closest duration.
    static func best(_ records: [Record], duration: Double) -> Record? {
        let usable = records.filter { $0.instrumental || $0.plain != nil || $0.synced != nil }
        let near = duration > 0 ? usable.filter { $0.duration <= 0 || abs($0.duration - duration) <= 5 } : usable
        return near.min { a, b in
            let aSynced = a.synced != nil, bSynced = b.synced != nil
            if aSynced != bSynced { return aSynced }
            return abs(a.duration - duration) < abs(b.duration - duration)
        }
    }

    /// Lyrics from a record: synced when it has them, plain otherwise.
    static func lyrics(from record: Record) -> Lyrics? {
        if record.instrumental, record.synced == nil, record.plain == nil {
            return Lyrics(lines: [], source: .lrclib, instrumental: true)
        }
        if let synced = record.synced {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return Lyrics(lines: lines, source: .lrclib) }
        }
        if let plain = record.plain {
            let lines = parsePlain(plain)
            if !lines.isEmpty { return Lyrics(lines: lines, source: .lrclib) }
        }
        return nil
    }

    /// A title as lyrics databases know it: without "- Remastered 2011", "(feat. …)", "[Live]" and the like.
    static func cleanTitle(_ title: String) -> String {
        var result = title
        // " - Remastered", " - Radio Edit", " - From the film …"
        if let dash = result.range(of: " - ") { result = String(result[..<dash.lowerBound]) }
        let noise = ["feat", "ft.", "with ", "remaster", "live", "version", "edit", "mix", "mono", "stereo", "deluxe", "bonus"]
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = result.range(of: open, options: .backwards),
                  let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                let inside = result[start.upperBound..<end.lowerBound].lowercased()
                guard noise.contains(where: { inside.contains($0) }) else { break }
                result.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// The first artist of "A, B & C" or "A feat. B".
    static func primaryArtist(_ artist: String) -> String {
        var result = artist
        for separator in [", ", " & ", " feat. ", " ft. ", " featuring "] {
            if let range = result.range(of: separator, options: .caseInsensitive) { result = String(result[..<range.lowerBound]) }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? artist : trimmed
    }
}

// MARK: Queue, playlists and recent tracks

/// A track in Up Next, a playlist or the recent list. `id` is what the player plays it by: a Music persistent ID or a
/// Spotify URI (`spotify:track:…`).
struct MusicTrack: Equatable, Identifiable {
    var id: String
    var title: String
    var artist: String
    var duration: Int
    var artworkURL: URL? = nil
}

struct MusicPlaylist: Equatable, Identifiable {
    var id: String
    var name: String
    var trackCount: Int
}

/// Placeholder colours for things without artwork (Music's queue, playlists): the same name always gets the same pick,
/// across launches, so a cover is recognisable from one visit to the next.
enum MusicCoverPalette {
    static func index(for seed: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt32 = 5381
        for scalar in seed.unicodeScalars { hash = (hash &* 33) &+ scalar.value }
        return Int(hash % UInt32(count))
    }
}

/// The tracks after the current one in the playlist Music plays from.
struct MusicQueue: Equatable {
    var playlist: String
    var tracks: [MusicTrack]
}

/// The scripts separate records with ASCII 30 and fields with ASCII 31: unlike tabs and newlines, those never occur in a
/// title.
enum MusicScriptOutput {
    static let record: Character = "\u{1E}"
    static let field: Character = "\u{1F}"

    private static func records(_ raw: String) -> [[String]] {
        raw.split(separator: record, omittingEmptySubsequences: false).map {
            $0.split(separator: field, omittingEmptySubsequences: false).map { String($0) }
        }
    }

    private static func value(_ text: String) -> String {
        text == "missing value" ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First record: playlist name. Then one record per track: id, title, artist, duration in seconds.
    static func queue(_ raw: String) -> MusicQueue? {
        let rows = records(raw)
        guard let header = rows.first, let name = header.first, !raw.isEmpty else { return nil }
        return MusicQueue(playlist: value(name), tracks: rows.dropFirst().compactMap(track))
    }

    /// One record per playlist: id, name, track count.
    static func playlists(_ raw: String) -> [MusicPlaylist] {
        guard !raw.isEmpty else { return [] }
        return records(raw).compactMap { fields in
            guard fields.count >= 3, !value(fields[0]).isEmpty, !value(fields[1]).isEmpty else { return nil }
            return MusicPlaylist(id: value(fields[0]), name: value(fields[1]), trackCount: Int(value(fields[2])) ?? 0)
        }
    }

    private static func track(_ fields: [String]) -> MusicTrack? {
        guard fields.count >= 4, !value(fields[0]).isEmpty, !value(fields[1]).isEmpty else { return nil }
        let seconds = Double(value(fields[3]).replacingOccurrences(of: ",", with: ".")) ?? 0
        return MusicTrack(id: value(fields[0]), title: value(fields[1]), artist: value(fields[2]), duration: max(0, Int(seconds)))
    }

    /// Escapes text for an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Tracks played before the current one, newest first, each once.
struct RecentTracks: Equatable {
    static let limit = 30
    private(set) var tracks: [MusicTrack] = []

    mutating func add(_ track: MusicTrack) {
        tracks.removeAll { (!track.id.isEmpty && $0.id == track.id) || ($0.title == track.title && $0.artist == track.artist) }
        tracks.insert(track, at: 0)
        if tracks.count > Self.limit { tracks.removeLast(tracks.count - Self.limit) }
    }
}
