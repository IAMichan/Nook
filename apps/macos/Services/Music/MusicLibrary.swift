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
    var album = ""
}

/// A playlist in Music (`id` a persistent ID) or on Spotify (`id` a `spotify:playlist:…` URI).
struct MusicPlaylist: Equatable, Identifiable {
    var id: String
    var name: String
    var trackCount: Int
    var artworkURL: URL? = nil
    /// The user may add and remove tracks: not a smart playlist in Music, not someone else's playlist on Spotify.
    var editable = true
    /// Who made it, when that is not the user (Spotify).
    var owner = ""
}

/// How far loading something for the Music tab (a search, the playlists, a playlist's tracks) got.
enum MusicLoadState: Equatable {
    case idle, loading, done
    /// Spotify's playlists and search need its Web API, so Spotify must be connected in Settings first.
    case connectSpotify
    /// Spotify is connected, but without the permission this needs (it was connected before Nook asked for it).
    case reconnectSpotify
    case failed(String)
}

/// A playlist opened in the Music tab, with its tracks.
struct MusicPlaylistDetail: Equatable {
    var playlist: MusicPlaylist
    /// The player it belongs to: "Music" or "Spotify".
    var app: String
    var state = MusicLoadState.loading
    var tracks: [MusicTrack] = []

    /// A track with its position in the playlist (0-based).
    struct Row: Identifiable, Equatable {
        var index: Int
        var track: MusicTrack
        var id: Int { index }
    }

    /// Tracks whose title, artist or album contains every word of `filter`, in playlist order with their position.
    func tracks(matching filter: String) -> [Row] {
        let words = filter.lowercased().split(separator: " ").map(String.init)
        return tracks.enumerated().compactMap { index, track in
            let haystack = "\(track.title) \(track.artist) \(track.album)".lowercased()
            return words.allSatisfy { haystack.contains($0) } ? Row(index: index, track: track) : nil
        }
    }

    /// The total length in seconds.
    var duration: Int { tracks.reduce(0) { $0 + $1.duration } }
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

    /// One record per track, without a header: id, title, artist, duration in seconds (a library search).
    static func tracks(_ raw: String) -> [MusicTrack] {
        guard !raw.isEmpty else { return [] }
        return records(raw).compactMap(track)
    }

    /// One record per playlist: id, name, track count, and (optionally) whether it is a smart playlist.
    static func playlists(_ raw: String) -> [MusicPlaylist] {
        guard !raw.isEmpty else { return [] }
        return records(raw).compactMap { fields in
            guard fields.count >= 3, !value(fields[0]).isEmpty, !value(fields[1]).isEmpty else { return nil }
            let smart = fields.count >= 4 && value(fields[3]) == "true"
            return MusicPlaylist(id: value(fields[0]), name: value(fields[1]), trackCount: Int(value(fields[2])) ?? 0, editable: !smart)
        }
    }

    /// id, title, artist, duration in seconds, and (optionally) album.
    private static func track(_ fields: [String]) -> MusicTrack? {
        guard fields.count >= 4, !value(fields[0]).isEmpty, !value(fields[1]).isEmpty else { return nil }
        let seconds = Double(value(fields[3]).replacingOccurrences(of: ",", with: ".")) ?? 0
        return MusicTrack(id: value(fields[0]), title: value(fields[1]), artist: value(fields[2]), duration: max(0, Int(seconds)),
                          album: fields.count >= 5 ? value(fields[4]) : "")
    }

    /// Finds the user playlist with persistent ID `id` as `pl`, inside `tell application "Music"`.
    private static func findPlaylist(_ id: String) -> String {
        "set pl to (first user playlist whose persistent ID is \(quoted(id)))"
    }

    /// id/title/artist/duration/album of the first `limit` tracks of a Music playlist, in its order.
    static func playlistTracksScript(_ id: String, limit: Int) -> String {
        """
        with timeout of 10 seconds
        tell application "Music"
            set rs to character id 30
            set fs to character id 31
            \(findPlaylist(id))
            set n to count of tracks of pl
            if n > \(limit) then set n to \(limit)
            if n is 0 then return ""
            set ids to persistent ID of tracks 1 thru n of pl
            set names to name of tracks 1 thru n of pl
            set artists to artist of tracks 1 thru n of pl
            set durations to duration of tracks 1 thru n of pl
            set albums to album of tracks 1 thru n of pl
            set out to ""
            repeat with i from 1 to n
                set entry to (item i of ids) & fs & (item i of names) & fs & (item i of artists) & fs & ((item i of durations) as text) & fs & (item i of albums)
                if i is 1 then
                    set out to entry
                else
                    set out to out & rs & entry
                end if
            end repeat
            return out
        end tell
        end timeout
        """
    }

    /// Adds the library track with persistent ID `track` to the end of a Music playlist. Returns "ok".
    static func addToPlaylistScript(track: String, playlist: String) -> String {
        """
        with timeout of 8 seconds
        tell application "Music"
            \(findPlaylist(playlist))
            duplicate (first track of library playlist 1 whose persistent ID is \(quoted(track))) to pl
            return "ok"
        end tell
        end timeout
        """
    }

    /// Takes a track out of a Music playlist (not out of the library): the one at `position` (1-based) when it is still
    /// that track, otherwise the first with its persistent ID. Returns "ok".
    static func removeFromPlaylistScript(track: String, position: Int, playlist: String) -> String {
        """
        with timeout of 8 seconds
        tell application "Music"
            \(findPlaylist(playlist))
            set target to missing value
            try
                set candidate to track \(max(1, position)) of pl
                if persistent ID of candidate is \(quoted(track)) then set target to candidate
            end try
            if target is missing value then set target to (first track of pl whose persistent ID is \(quoted(track)))
            delete target
            return "ok"
        end tell
        end timeout
        """
    }

    /// Makes a new, empty user playlist and returns its persistent ID.
    static func createPlaylistScript(name: String) -> String {
        """
        with timeout of 8 seconds
        tell application "Music"
            set pl to make new user playlist with properties {name:\(quoted(name))}
            return persistent ID of pl
        end tell
        end timeout
        """
    }

    static func renamePlaylistScript(_ id: String, to name: String) -> String {
        """
        with timeout of 8 seconds
        tell application "Music"
            \(findPlaylist(id))
            set name of pl to \(quoted(name))
            return "ok"
        end tell
        end timeout
        """
    }

    static func deletePlaylistScript(_ id: String) -> String {
        """
        with timeout of 8 seconds
        tell application "Music"
            \(findPlaylist(id))
            delete pl
            return "ok"
        end tell
        end timeout
        """
    }

    /// Plays a Music playlist from its first track, or from the track with persistent ID `track` (so Music carries on
    /// through the playlist afterwards). `shuffle` turns shuffle on or off first; `nil` leaves it.
    static func playPlaylistScript(_ id: String, track: String? = nil, shuffle: Bool? = nil) -> String {
        let shuffleLine = shuffle.map { "set shuffle enabled to \($0)" } ?? ""
        let play = track.map { "play (first track of pl whose persistent ID is \(quoted($0)))" } ?? "play pl"
        return """
        with timeout of 6 seconds
        tell application "Music"
            \(findPlaylist(id))
            \(shuffleLine)
            \(play)
        end tell
        end timeout
        """
    }

    /// id/title/artist/duration of the first tracks in Music's library that match `query` in any field (name, artist,
    /// album, composer), as Music's own search field finds them. Not cached: the query is part of the source.
    static func librarySearchScript(_ query: String, limit: Int) -> String {
        """
        with timeout of 8 seconds
        tell application "Music"
            set rs to character id 30
            set fs to character id 31
            set out to ""
            set found to {}
            try
                set found to search library playlist 1 for \(MusicScriptOutput.quoted(query))
            end try
            if found is missing value then return ""
            set n to count of found
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                try
                    set tr to item i of found
                    set entry to (persistent ID of tr) & fs & (name of tr) & fs & (artist of tr) & fs & ((duration of tr) as text)
                    if out is "" then
                        set out to entry
                    else
                        set out to out & rs & entry
                    end if
                end try
            end repeat
            return out
        end tell
        end timeout
        """
    }

    /// Escapes text for an AppleScript string literal.
    static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// What the Music tab's search shows: the tracks found for `query`, in Music's library or on Spotify.
struct MusicSearchResult: Equatable {
    typealias State = MusicLoadState

    var query = ""
    var state = State.idle
    var tracks: [MusicTrack] = []
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

/// Tracks the user queued in Nook, in the order they play. Neither Music nor Spotify lets another app add to its own
/// queue, so Nook keeps this one and starts each track itself when the one before it ends (see
/// `NowPlayingService+Queue`). The same track may be queued more than once, so each entry has its own id.
struct MusicPlayQueue: Equatable {
    struct Entry: Equatable, Identifiable {
        var id = UUID()
        var track: MusicTrack
    }

    static let limit = 100
    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var tracks: [MusicTrack] { entries.map(\.track) }

    /// Adds a track at the end. `false` when the queue is full or the track has nothing to play it by.
    @discardableResult
    mutating func append(_ track: MusicTrack) -> Bool {
        guard !track.id.isEmpty, entries.count < Self.limit else { return false }
        entries.append(Entry(track: track))
        return true
    }

    mutating func remove(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
    }

    /// Takes out the entry with `id`, or the first one without.
    mutating func take(_ id: Entry.ID? = nil) -> MusicTrack? {
        guard let index = id.map({ id in entries.firstIndex { $0.id == id } }) ?? (entries.isEmpty ? nil : 0) else { return nil }
        return entries.remove(at: index).track
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// The player moved on by itself while tracks were queued: did the previous track end (so the queue should take
    /// over), or did the user pick something else in the player? `position` is where the previous track was estimated
    /// to be at the change; one that got within a few seconds of its end ended.
    static func ended(position: Double, duration: Int) -> Bool {
        duration > 0 && position >= Double(duration) - 3
    }
}

/// What Spotify's Web API answers (see `SpotifyWebAPI`), read without the network so it can be tested.
enum SpotifyResponses {
    enum Failure: Error, Equatable {
        case notSignedIn
        /// Spotify answered 403: the account has no Premium.
        case premiumRequired
        /// Spotify answered 404: no device is playing.
        case noActiveDevice
        /// Spotify answered 403 because the sign-in lacks a permission (it was made before Nook asked for it).
        case missingScope
        case failed(String)
    }

    /// The tracks in `GET /me/player/queue`, in the order Spotify plays them. Episodes count too.
    static func queueTracks(from data: Data) -> [MusicTrack] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["queue"] as? [[String: Any]] else { return [] }
        return items.compactMap(track)
    }

    /// The tracks `GET /search?type=track` found, best match first. Spotify leaves `null` in the list for tracks it
    /// cannot show; those are skipped.
    static func searchTracks(from data: Data) -> [MusicTrack] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = (json["tracks"] as? [String: Any])?["items"] as? [Any] else { return [] }
        return items.compactMap { ($0 as? [String: Any]).flatMap(track) }
    }

    // MARK: Playlists

    /// The bare id in `spotify:playlist:<id>`, or `nil` for anything else.
    static func playlistID(_ uri: String) -> String? {
        let parts = uri.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "spotify", parts[1] == "playlist", !parts[2].isEmpty, parts[2].count <= 64,
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return String(parts[2])
    }

    /// The user's own id in `GET /me`.
    static func userID(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
    }

    /// The `next` page of a paged answer, or `nil` on the last page.
    static func nextPage(from data: Data) -> URL? {
        ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["next"] as? String).flatMap(URL.init(string:))
    }

    /// The playlists in a page of `GET /me/playlists`. A playlist is editable when `userID` owns it or it is
    /// collaborative. Spotify renamed the playlist's `tracks` count to `items` in 2026; both are read.
    static func playlists(from data: Data, userID: String?) -> [MusicPlaylist] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [Any] else { return [] }
        return items.compactMap { ($0 as? [String: Any]).flatMap { playlist($0, userID: userID) } }
    }

    /// One playlist object (`GET /me/playlists`, `POST /me/playlists`).
    static func playlist(_ item: [String: Any], userID: String?) -> MusicPlaylist? {
        guard let uri = item["uri"] as? String, playlistID(uri) != nil, let name = item["name"] as? String else { return nil }
        let count = ((item["items"] ?? item["tracks"]) as? [String: Any])?["total"] as? Int ?? 0
        let images = item["images"] as? [[String: Any]] ?? []
        let owner = item["owner"] as? [String: Any]
        let ownerID = owner?["id"] as? String
        let mine = userID != nil && ownerID == userID
        return MusicPlaylist(
            id: uri, name: name, trackCount: count,
            artworkURL: ((images.last { (($0["width"] as? Int) ?? 300) >= 200 } ?? images.first)?["url"] as? String).flatMap(URL.init(string:)),
            editable: mine || (item["collaborative"] as? Bool ?? false),
            owner: mine ? "" : (owner?["display_name"] as? String ?? ownerID ?? "")
        )
    }

    /// The tracks in a page of a playlist's items. Each entry holds its track under `item` (since 2026) or `track`;
    /// local files and tracks Spotify cannot show (`null`) are skipped.
    static func playlistTracks(from data: Data) -> [MusicTrack] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [Any] else { return [] }
        return items.compactMap { entry in
            guard let entry = entry as? [String: Any],
                  let object = (entry["item"] ?? entry["track"]) as? [String: Any],
                  (object["is_local"] as? Bool) != true else { return nil }
            return track(object)
        }
    }

    static func request(_ url: URL, method: String = "GET", json: [String: Any]? = nil, token: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let json, let body = try? JSONSerialization.data(withJSONObject: json) {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    /// One track or episode object.
    private static func track(_ item: [String: Any]) -> MusicTrack? {
        guard let uri = item["uri"] as? String, let name = item["name"] as? String, !name.isEmpty else { return nil }
        let artists = (item["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        let show = (item["show"] as? [String: Any])?["name"] as? String
        let images = ((item["album"] as? [String: Any])?["images"] ?? item["images"]) as? [[String: Any]] ?? []
        // The smallest image that is still sharp on a cover (Spotify lists them largest first).
        let image = images.last { (($0["width"] as? Int) ?? 0) >= 200 } ?? images.first
        let milliseconds = (item["duration_ms"] as? Int) ?? 0
        return MusicTrack(
            id: uri, title: name, artist: artists.isEmpty ? (show ?? "") : artists.joined(separator: ", "),
            duration: milliseconds / 1000, artworkURL: (image?["url"] as? String).flatMap(URL.init(string:)),
            album: (item["album"] as? [String: Any])?["name"] as? String ?? show ?? ""
        )
    }

    /// Spotify allows at most 10 search results per page for apps in development mode, so a longer list is asked for
    /// page by page with `offset`.
    static let searchPageSize = 10

    /// `GET /search` for tracks.
    static func searchRequest(query: String, offset: Int, token: String) -> URLRequest? {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: String(searchPageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func failure(status: Int, body: Data) -> Failure? {
        switch status {
        case 200..<300: return nil
        case 401: return .notSignedIn
        case 403:
            let message = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            return message?.lowercased().contains("scope") == true ? .missingScope : .premiumRequired
        case 404: return .noActiveDevice
        default:
            let message = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["error"] as? [String: Any])?["message"] as? String
            return .failed(message ?? "HTTP \(status)")
        }
    }
}
