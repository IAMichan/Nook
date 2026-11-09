import Foundation

// What Nook remembers of the user's listening: Recent, recent searches and a log of plays, with the statistics made from
// them. Plain data, so it can be tested without a player. Saving and watching the player live in
// `NowPlayingService+History`; nothing here leaves the Mac.

/// One track listened to. `playedAt` is when it ended, as Spotify's own history counts it.
struct MusicPlay: Codable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album = ""
    var app: String
    var artworkURL: URL? = nil
    var duration: Int
    /// Seconds actually listened to.
    var listened: Int
    var playedAt: Date

    /// The same recording, also when the player gave no id.
    var key: String { id.isEmpty ? "\(artist)|\(title)" : id }

    var track: MusicTrack {
        MusicTrack(id: id, title: title, artist: artist, duration: duration, artworkURL: artworkURL, album: album)
    }
}

/// Everything Nook keeps, saved as one file.
struct MusicHistory: Codable, Equatable {
    /// A year or more of listening, and a file that stays a few megabytes.
    static let playLimit = 10_000
    static let searchLimit = 8
    /// A play from the player's own history this close to one Nook measured is the same play.
    static let samePlayWindow: TimeInterval = 600

    /// Oldest first.
    private(set) var plays: [MusicPlay] = []
    var recent = RecentTracks()
    /// Newest first, each once.
    private(set) var searches: [String] = []

    var isEmpty: Bool { plays.isEmpty && recent.tracks.isEmpty && searches.isEmpty }

    mutating func add(_ play: MusicPlay) {
        plays.append(play)
        trim()
    }

    /// Adds plays from the player's own history that Nook did not see itself. `true` when any were new.
    @discardableResult
    mutating func merge(imported: [MusicPlay]) -> Bool {
        var byKey = Dictionary(grouping: plays, by: \.key).mapValues { $0.map(\.playedAt) }
        let fresh = imported.filter { play in
            let known = byKey[play.key]?.contains { abs($0.timeIntervalSince(play.playedAt)) < Self.samePlayWindow } ?? false
            if !known { byKey[play.key, default: []].append(play.playedAt) }
            return !known
        }
        guard !fresh.isEmpty else { return false }
        plays = (plays + fresh).sorted { $0.playedAt < $1.playedAt }
        trim()
        return true
    }

    /// Remembers what was searched for. Differently cased, it is the same search.
    mutating func remember(search text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        searches.removeAll { $0.caseInsensitiveCompare(query) == .orderedSame }
        searches.insert(query, at: 0)
        if searches.count > Self.searchLimit { searches.removeLast(searches.count - Self.searchLimit) }
    }

    mutating func forget(search text: String) {
        searches.removeAll { $0 == text }
    }

    private mutating func trim() {
        if plays.count > Self.playLimit { plays.removeFirst(plays.count - Self.playLimit) }
    }
}

/// Follows the playing track and measures how long it really sounded. `update` hands back a finished play when the track
/// changes and it counts: half the track, or 30 seconds of a longer one, like a play on Spotify or Last.fm.
struct MusicListening: Equatable {
    /// Without a length (a stream) a track counts this long at most.
    static let streamLimit = 3 * 3600.0

    private var draft: MusicPlay?
    private var since: Date?
    private var seconds = 0.0

    /// Call with what plays now (`nil` for nothing) on every change, and with `at:` the moment of the change.
    mutating func update(_ playing: MusicPlay?, isPlaying: Bool, at now: Date) -> MusicPlay? {
        if let since { seconds += max(0, now.timeIntervalSince(since)) }
        since = nil
        var finished: MusicPlay?
        if draft?.key != playing?.key {
            finished = finish(at: now)
            draft = playing
            seconds = 0
        }
        if draft != nil, isPlaying { since = now }
        return finished
    }

    /// The Mac quits: what was playing counts as far as it got.
    mutating func finish(at now: Date) -> MusicPlay? {
        if let since { seconds += max(0, now.timeIntervalSince(since)) }
        since = nil
        guard var play = draft else { return nil }
        // Not longer than the track: asleep the clock runs on, and a repeated track stays one play.
        let heard = min(seconds, play.duration > 0 ? Double(play.duration) : Self.streamLimit)
        draft = nil
        seconds = 0
        guard Self.counts(heard, duration: play.duration) else { return nil }
        play.listened = Int(heard)
        play.playedAt = now
        return play
    }

    static func counts(_ heard: Double, duration: Int) -> Bool {
        heard >= (duration > 0 ? min(30, Double(duration) / 2) : 30)
    }
}

/// The time the statistics look back over. Rolling, so a Monday morning still has a week to show.
enum MusicStatsPeriod: String, CaseIterable, Identifiable {
    case week, month, year, all
    var id: String { rawValue }

    /// The first moment of the period, or `nil` for everything.
    func start(now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .year:
            let month = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
            return calendar.date(byAdding: .month, value: -11, to: month)
        case .all: return nil
        }
    }

    /// The same length just before `start`, to compare with.
    func previousStart(before start: Date, calendar: Calendar) -> Date? {
        switch self {
        case .week: return calendar.date(byAdding: .day, value: -7, to: start)
        case .month: return calendar.date(byAdding: .day, value: -30, to: start)
        case .year: return calendar.date(byAdding: .month, value: -12, to: start)
        case .all: return nil
        }
    }

    /// Bars per day for the short periods, per month for the long ones.
    var byDay: Bool { self == .week || self == .month }
}

/// The part of the day someone listens most.
enum MusicListenerType: String, Equatable {
    case morning, afternoon, evening, night

    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<18: self = .afternoon
        case 18..<23: self = .evening
        default: self = .night
        }
    }
}

/// The statistics over one period.
struct MusicStats: Equatable {
    struct Bucket: Equatable, Identifiable {
        var start: Date
        var seconds: Int
        var id: Date { start }
    }

    struct TrackRank: Equatable, Identifiable {
        var track: MusicTrack
        var plays: Int
        var seconds: Int
        var id: String { track.id.isEmpty ? "\(track.artist)|\(track.title)" : track.id }
    }

    struct ArtistRank: Equatable, Identifiable {
        var name: String
        var plays: Int
        var seconds: Int
        var artworkURL: URL?
        var id: String { name }
    }

    static let rankLimit = 10

    var period: MusicStatsPeriod
    var seconds = 0
    var plays = 0
    var uniqueTracks = 0
    var uniqueArtists = 0
    /// The period before, for the comparison. `nil` when there is nothing to compare with.
    var previousSeconds: Int?
    var buckets: [Bucket] = []
    /// Seconds per hour of the day, 0 to 23.
    var hours = [Int](repeating: 0, count: 24)
    /// Seconds per day of the week and hour: seven rows from the calendar's first weekday, 24 hours each.
    var weekHours = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
    /// Artists in this period that were never played before it. `nil` for all time, which has no before.
    var newArtists: Int?
    var topTracks: [TrackRank] = []
    var topArtists: [ArtistRank] = []
    /// Days in a row with music, up to today or yesterday.
    var streak = 0
    /// The day with the most listening.
    var bestDay: Bucket?
    var peakHour: Int?
    var listenerType: MusicListenerType?

    var isEmpty: Bool { plays == 0 }

    /// The change against the period before in percent, when it can be said.
    var change: Int? {
        guard let previousSeconds, previousSeconds > 0 else { return nil }
        return Int((Double(seconds - previousSeconds) / Double(previousSeconds) * 100).rounded())
    }

    /// `plays` oldest first, as `MusicHistory` keeps them.
    init(plays all: [MusicPlay], period: MusicStatsPeriod, now: Date = Date(), calendar: Calendar = .current) {
        self.period = period
        let start = period.start(now: now, calendar: calendar)
        let shown = all.filter { play in play.playedAt <= now && start.map { play.playedAt >= $0 } ?? true }
        streak = Self.streak(all, now: now, calendar: calendar)
        if let start, let before = period.previousStart(before: start, calendar: calendar) {
            let earlier = all.filter { $0.playedAt >= before && $0.playedAt < start }
            previousSeconds = earlier.isEmpty ? nil : earlier.reduce(0) { $0 + $1.listened }
        }
        buckets = Self.emptyBuckets(period: period, first: all.first?.playedAt, now: now, calendar: calendar)
        guard !shown.isEmpty else { return }

        plays = shown.count
        seconds = shown.reduce(0) { $0 + $1.listened }
        let bucketIndex = Dictionary(uniqueKeysWithValues: buckets.enumerated().map { ($1.start, $0) })
        var days: [Date: Int] = [:]
        var tracks: [String: TrackRank] = [:]
        var artists: [String: ArtistRank] = [:]
        for play in shown {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .weekday], from: play.playedAt)
            let day = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day)) ?? play.playedAt
            days[day, default: 0] += play.listened
            let bucket = period.byDay ? day : calendar.date(from: DateComponents(year: parts.year, month: parts.month)) ?? day
            if let index = bucketIndex[bucket] { buckets[index].seconds += play.listened }
            if let hour = parts.hour, hours.indices.contains(hour) {
                hours[hour] += play.listened
                if let weekday = parts.weekday {
                    weekHours[(weekday - calendar.firstWeekday + 7) % 7][hour] += play.listened
                }
            }

            var rank = tracks[play.key] ?? TrackRank(track: play.track, plays: 0, seconds: 0)
            rank.plays += 1
            rank.seconds += play.listened
            rank.track = play.track
            tracks[play.key] = rank

            guard !play.artist.isEmpty else { continue }
            var artist = artists[play.artist] ?? ArtistRank(name: play.artist, plays: 0, seconds: 0, artworkURL: nil)
            artist.plays += 1
            artist.seconds += play.listened
            artist.artworkURL = play.artworkURL ?? artist.artworkURL
            artists[play.artist] = artist
        }
        uniqueTracks = tracks.count
        uniqueArtists = artists.count
        if let start {
            let known = Set(all.lazy.filter { $0.playedAt < start }.map(\.artist))
            newArtists = artists.keys.filter { !known.contains($0) }.count
        }
        topTracks = Array(tracks.values.sorted { ($0.plays, $0.seconds, $1.track.title) > ($1.plays, $1.seconds, $0.track.title) }.prefix(Self.rankLimit))
        topArtists = Array(artists.values.sorted { ($0.seconds, $1.name) > ($1.seconds, $0.name) }.prefix(Self.rankLimit))
        bestDay = days.max { ($0.value, $1.key) < ($1.value, $0.key) }.map { Bucket(start: $0.key, seconds: $0.value) }
        if let peak = hours.indices.max(by: { hours[$0] < hours[$1] }), hours[peak] > 0 {
            peakHour = peak
            // By the part of the day, not one peak hour: an evening spread over hours beats one busy lunch.
            var parts: [MusicListenerType: Int] = [:]
            for hour in hours.indices { parts[MusicListenerType(hour: hour), default: 0] += hours[hour] }
            listenerType = plays >= 5 ? parts.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key : nil
        }
    }

    /// One empty bar for every day or month of the period, so a silent day shows as a gap.
    private static func emptyBuckets(period: MusicStatsPeriod, first: Date?, now: Date, calendar: Calendar) -> [Bucket] {
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        var start = period.start(now: now, calendar: calendar)
        if period == .all {
            // Every month since the first play, half a year at least and two years at most.
            let earliest = calendar.date(byAdding: .month, value: -23, to: thisMonth) ?? thisMonth
            let latest = calendar.date(byAdding: .month, value: -5, to: thisMonth) ?? thisMonth
            let firstMonth = first.flatMap { calendar.date(from: calendar.dateComponents([.year, .month], from: $0)) } ?? latest
            start = max(earliest, min(latest, firstMonth))
        }
        guard var date = start else { return [] }
        let step: Calendar.Component = period.byDay ? .day : .month
        let end = period.byDay ? calendar.startOfDay(for: now) : thisMonth
        var result: [Bucket] = []
        while date <= end, result.count < 40 {
            result.append(Bucket(start: date, seconds: 0))
            guard let next = calendar.date(byAdding: step, value: 1, to: date) else { break }
            date = next
        }
        return result
    }

    private static func streak(_ plays: [MusicPlay], now: Date, calendar: Calendar) -> Int {
        let days = Set(plays.map { calendar.startOfDay(for: $0.playedAt) })
        var day = calendar.startOfDay(for: now)
        // Today may still come; the streak only breaks when yesterday stayed silent too.
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while days.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

/// The user's own top lists as the player keeps them, older than anything Nook saw: Spotify's top of the last six months,
/// Music's all-time play counts.
struct MusicPlayerStats: Equatable {
    struct Artist: Equatable, Identifiable {
        var name: String
        var plays: Int? = nil
        var artworkURL: URL? = nil
        var id: String { name }
    }

    var app = ""
    var tracks: [MusicTrack] = []
    var artists: [Artist] = []
    /// Play counts by track id, where the player has them (Music).
    var plays: [String: Int] = [:]
    var state = MusicLoadState.idle
}

/// Whether Nook must put a player back after asking it to play: the point is that a click in Nook never brings it up.
struct MusicPlayerFocus: Equatable {
    /// The frontmost app before Nook asked (a bundle id).
    var frontmost: String?
    var playerBundleID: String
    /// The player was hidden, or Nook just started it: nobody had it on screen.
    var wasOutOfSight: Bool

    /// The player took the front from the app the user was in.
    func stoleFront(now frontmostNow: String?) -> Bool {
        frontmostNow == playerBundleID && frontmost != playerBundleID
    }

    /// Hide it again. A player the user keeps on screen stays where it is.
    var shouldHide: Bool { wasOutOfSight && frontmost != playerBundleID }
}
