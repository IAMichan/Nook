import XCTest

final class MusicLibraryTests: XCTestCase {
    // MARK: LRC

    func testParsesTimedLinesInOrder() {
        let lines = LyricsParser.parseLRC("""
        [ti:Example]
        [ar:Someone]
        [00:12.50] Second line
        [00:03.00]First line
        [01:02.25]Third line
        """)
        XCTAssertEqual(lines.map(\.text), ["First line", "Second line", "Third line"])
        XCTAssertEqual(lines.map(\.time), [3, 12.5, 62.25])
        XCTAssertEqual(lines.map(\.id), [0, 1, 2])
    }

    func testRepeatedStampsAndOffset() {
        let lines = LyricsParser.parseLRC("""
        [offset:+500]
        [00:10.00][00:30.00]Chorus
        [00:20.00]Verse
        [00:40.00]
        """)
        XCTAssertEqual(lines.map(\.text), ["Chorus", "Verse", "Chorus", ""])
        XCTAssertEqual(lines.map(\.time), [9.5, 19.5, 29.5, 39.5])
    }

    func testTimestampFormats() {
        XCTAssertEqual(LyricsParser.timestamp("01:05"), 65)
        XCTAssertEqual(LyricsParser.timestamp("01:05.5"), 65.5)
        XCTAssertEqual(LyricsParser.timestamp("01:05:50"), 65.5)
        XCTAssertNil(LyricsParser.timestamp("ar:Someone"))
        XCTAssertNil(LyricsParser.timestamp("00:75"))
    }

    func testPlainTextWithoutStampsIsNotLRC() {
        XCTAssertTrue(LyricsParser.parseLRC("Just words\nMore words").isEmpty)
    }

    func testPlainCollapsesBlankLines() {
        let lines = LyricsParser.parsePlain("\nOne\n\n\n\nTwo\r\nThree\n\n")
        XCTAssertEqual(lines.map(\.text), ["One", "", "Two", "Three"])
        XCTAssertTrue(lines.allSatisfy { $0.time == nil })
    }

    func testActiveIndexFollowsPosition() {
        let lyrics = Lyrics(lines: LyricsParser.parseLRC("[00:05.00]A\n[00:10.00]B\n[00:20.00]C"), source: .lrclib)
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertNil(lyrics.activeIndex(at: 2))
        XCTAssertEqual(lyrics.activeIndex(at: 5), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 19.9), 1)
        XCTAssertEqual(lyrics.activeIndex(at: 500), 2)
        let plain = Lyrics(lines: LyricsParser.parsePlain("A\nB"), source: .player)
        XCTAssertFalse(plain.isSynced)
        XCTAssertNil(plain.activeIndex(at: 10))
    }

    // MARK: LRCLIB

    func testDecodesSingleRecordAndPrefersSynced() throws {
        let json = #"{"id":1,"trackName":"Song","artistName":"Band","duration":200,"instrumental":false,"plainLyrics":"Alpha\nBeta","syncedLyrics":"[00:01.00]Alpha\n[00:02.00]Beta"}"#
        let record = try XCTUnwrap(LyricsParser.records(from: Data(json.utf8)).first)
        let lyrics = try XCTUnwrap(LyricsParser.lyrics(from: record))
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertEqual(lyrics.lines.map(\.text), ["Alpha", "Beta"])
        XCTAssertEqual(lyrics.source, .lrclib)
    }

    func testInstrumentalAndEmptyRecords() throws {
        let json = #"[{"id":1,"trackName":"Song","duration":100,"instrumental":true,"plainLyrics":null,"syncedLyrics":null},{"id":2,"trackName":"Other","duration":100,"plainLyrics":"  "}]"#
        let records = LyricsParser.records(from: Data(json.utf8))
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(LyricsParser.lyrics(from: records[0])?.instrumental, true)
        XCTAssertNil(LyricsParser.lyrics(from: records[1]))
        XCTAssertTrue(LyricsParser.records(from: Data(#"{"code":404,"message":"Not found"}"#.utf8)).isEmpty)
    }

    func testBestRecordMatchesDurationThenSynced() {
        func record(_ duration: Double, synced: Bool) -> LyricsParser.Record {
            LyricsParser.Record(trackName: "S", artistName: "A", duration: duration, instrumental: false,
                                plain: "x", synced: synced ? "[00:01.00]x" : nil)
        }
        let candidates = [record(300, synced: true), record(181, synced: false), record(184, synced: true)]
        XCTAssertEqual(LyricsParser.best(candidates, duration: 180)?.duration, 184, "synced within 5 s wins over a closer plain one")
        XCTAssertNil(LyricsParser.best([record(300, synced: true)], duration: 180), "another recording")
        XCTAssertEqual(LyricsParser.best(candidates, duration: 0)?.synced != nil, true)
    }

    func testCleanTitleAndArtist() {
        XCTAssertEqual(LyricsParser.cleanTitle("Song Name - Remastered 2011"), "Song Name")
        XCTAssertEqual(LyricsParser.cleanTitle("Song Name (feat. Somebody)"), "Song Name")
        XCTAssertEqual(LyricsParser.cleanTitle("Song Name [Live]"), "Song Name")
        XCTAssertEqual(LyricsParser.cleanTitle("Song (Part 2)"), "Song (Part 2)")
        XCTAssertEqual(LyricsParser.primaryArtist("Band A, Band B & Band C"), "Band A")
        XCTAssertEqual(LyricsParser.primaryArtist("Band A feat. Band B"), "Band A")
    }

    // MARK: Script output

    func testParsesQueue() throws {
        let rs = "\u{1E}", fs = "\u{1F}"
        let raw = "Road Trip" + rs + "ABCDEF0123456789" + fs + "One" + fs + "Band" + fs + "201,5" + rs + "0123456789ABCDEF" + fs + "Two" + fs + "missing value" + fs + "90" + rs + "" + fs + "Broken"
        let queue = try XCTUnwrap(MusicScriptOutput.queue(raw))
        XCTAssertEqual(queue.playlist, "Road Trip")
        XCTAssertEqual(queue.tracks.map(\.title), ["One", "Two"])
        XCTAssertEqual(queue.tracks.map(\.duration), [201, 90])
        XCTAssertEqual(queue.tracks[1].artist, "")
        XCTAssertNil(MusicScriptOutput.queue(""))
        XCTAssertEqual(MusicScriptOutput.queue("Empty list")?.tracks, [])
    }

    func testParsesPlaylists() {
        let rs = "\u{1E}", fs = "\u{1F}"
        let raw = "AAAA" + fs + "Favourites" + fs + "42" + rs + "BBBB" + fs + "" + fs + "3" + rs + "CCCC" + fs + "Chill" + fs + "7"
        XCTAssertEqual(MusicScriptOutput.playlists(raw).map(\.name), ["Favourites", "Chill"])
        XCTAssertEqual(MusicScriptOutput.playlists(raw).first?.trackCount, 42)
        XCTAssertTrue(MusicScriptOutput.playlists("").isEmpty)
        XCTAssertTrue(MusicScriptOutput.playlists(raw).allSatisfy(\.editable))
    }

    func testSmartPlaylistsAreNotEditable() {
        let rs = "\u{1E}", fs = "\u{1F}"
        let raw = "AAAA" + fs + "Mine" + fs + "4" + fs + "false" + rs + "BBBB" + fs + "Recently Added" + fs + "25" + fs + "true"
        XCTAssertEqual(MusicScriptOutput.playlists(raw).map(\.editable), [true, false])
    }

    func testPlaylistTracksKeepTheirAlbum() {
        let rs = "\u{1E}", fs = "\u{1F}"
        let raw = "A1" + fs + "One" + fs + "Artist" + fs + "200,5" + fs + "Album" + rs + "B2" + fs + "Two" + fs + "" + fs + "60"
        let tracks = MusicScriptOutput.tracks(raw)
        XCTAssertEqual(tracks.map(\.album), ["Album", ""])
        XCTAssertEqual(tracks.map(\.duration), [200, 60])
    }

    func testPlaylistScriptsQuoteNames() {
        let script = MusicScriptOutput.createPlaylistScript(name: #"Road "Trip""#)
        XCTAssertTrue(script.contains(#"{name:"Road \"Trip\""}"#))
        let remove = MusicScriptOutput.removeFromPlaylistScript(track: "ABCD", position: 0, playlist: "EF01")
        XCTAssertTrue(remove.contains("track 1 of pl"))
        XCTAssertTrue(remove.contains(#"persistent ID is "EF01""#))
        XCTAssertTrue(MusicScriptOutput.playPlaylistScript("EF01", shuffle: true).contains("set shuffle enabled to true"))
        XCTAssertTrue(MusicScriptOutput.playPlaylistScript("EF01", track: "ABCD").contains(#"whose persistent ID is "ABCD")"#))
    }

    func testFilterOpenPlaylistKeepsPositions() {
        let detail = MusicPlaylistDetail(playlist: MusicPlaylist(id: "P", name: "P", trackCount: 3), app: "Music", state: .done, tracks: [
            MusicTrack(id: "1", title: "Get Lucky", artist: "Daft Punk", duration: 240),
            MusicTrack(id: "2", title: "Hey Jude", artist: "The Beatles", duration: 420),
            MusicTrack(id: "3", title: "One More Time", artist: "Daft Punk", duration: 320, album: "Discovery"),
        ])
        XCTAssertEqual(detail.tracks(matching: "daft discovery").map(\.index), [2])
        XCTAssertEqual(detail.tracks(matching: "").count, 3)
        XCTAssertEqual(detail.duration, 980)
    }

    func testQuotedEscapesForAppleScript() {
        XCTAssertEqual(MusicScriptOutput.quoted(#"a "b" \c"#), #""a \"b\" \\c""#)
    }

    func testRecentKeepsNewestFirstWithoutDuplicates() {
        var recent = RecentTracks()
        recent.add(MusicTrack(id: "1", title: "One", artist: "A", duration: 1))
        recent.add(MusicTrack(id: "2", title: "Two", artist: "A", duration: 1))
        recent.add(MusicTrack(id: "1", title: "One", artist: "A", duration: 1))
        XCTAssertEqual(recent.tracks.map(\.id), ["1", "2"])
        for index in 0..<50 { recent.add(MusicTrack(id: "x\(index)", title: "T\(index)", artist: "", duration: 0)) }
        XCTAssertEqual(recent.tracks.count, RecentTracks.limit)
        XCTAssertEqual(recent.tracks.first?.id, "x49")
    }

    func testCoverPaletteIsStableAndInRange() {
        let index = MusicCoverPalette.index(for: "Workout Mix", count: 7)
        XCTAssertEqual(MusicCoverPalette.index(for: "Workout Mix", count: 7), index)
        XCTAssertTrue((0..<7).contains(index))
        // djb2 of "a" is 5381 * 33 + 97 = 177670, and 177670 % 7 = 3: no per-launch hash seed.
        XCTAssertEqual(MusicCoverPalette.index(for: "a", count: 7), 3)
        XCTAssertEqual(MusicCoverPalette.index(for: "", count: 7), Int(5381 % 7))
        XCTAssertEqual(MusicCoverPalette.index(for: "anything", count: 0), 0)
        let spread = Set(["Focus", "Favorites", "Road trip", "Sunday", "Workout Mix", "New finds", "Chill"].map { MusicCoverPalette.index(for: $0, count: 7) })
        XCTAssertGreaterThan(spread.count, 2)
    }

    // MARK: Nook's queue

    private func track(_ id: String) -> MusicTrack { MusicTrack(id: id, title: "T\(id)", artist: "A", duration: 200) }

    func testQueuePlaysInOrderAndAllowsRepeats() {
        var queue = MusicPlayQueue()
        XCTAssertTrue(queue.append(track("1")))
        XCTAssertTrue(queue.append(track("2")))
        XCTAssertTrue(queue.append(track("1")))
        XCTAssertEqual(queue.tracks.map(\.id), ["1", "2", "1"])
        XCTAssertEqual(queue.take()?.id, "1")
        XCTAssertEqual(queue.tracks.map(\.id), ["2", "1"])
    }

    func testQueueTakesAndRemovesByEntry() {
        var queue = MusicPlayQueue()
        queue.append(track("1"))
        queue.append(track("2"))
        queue.append(track("3"))
        let middle = queue.entries[1].id
        XCTAssertEqual(queue.take(middle)?.id, "2")
        XCTAssertNil(queue.take(middle))
        queue.remove(queue.entries[0].id)
        XCTAssertEqual(queue.tracks.map(\.id), ["3"])
        queue.clear()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.take())
    }

    func testQueueRefusesTracksWithoutIDAndPastTheLimit() {
        var queue = MusicPlayQueue()
        XCTAssertFalse(queue.append(MusicTrack(id: "", title: "Radio", artist: "", duration: 0)))
        for index in 0..<MusicPlayQueue.limit { queue.append(track("\(index)")) }
        XCTAssertFalse(queue.append(track("x")))
        XCTAssertEqual(queue.entries.count, MusicPlayQueue.limit)
    }

    func testTrackEndedOnlyNearItsEnd() {
        XCTAssertTrue(MusicPlayQueue.ended(position: 199, duration: 200))
        XCTAssertTrue(MusicPlayQueue.ended(position: 200, duration: 200))
        XCTAssertFalse(MusicPlayQueue.ended(position: 120, duration: 200))
        XCTAssertFalse(MusicPlayQueue.ended(position: 10, duration: 0))
    }

    // MARK: Spotify Web API

    func testReadsSpotifyQueue() {
        let json = """
        {"currently_playing": {"uri": "spotify:track:now", "name": "Now"},
         "queue": [
           {"uri": "spotify:track:abc", "name": "First", "duration_ms": 201500,
            "artists": [{"name": "A"}, {"name": "B"}],
            "album": {"images": [{"url": "https://i.scdn.co/640", "width": 640}, {"url": "https://i.scdn.co/300", "width": 300},
                                 {"url": "https://i.scdn.co/64", "width": 64}]}},
           {"uri": "spotify:episode:xyz", "name": "Episode", "duration_ms": 60000, "show": {"name": "Podcast"}},
           {"uri": "spotify:track:nameless"}
         ]}
        """
        let tracks = SpotifyResponses.queueTracks(from: Data(json.utf8))
        XCTAssertEqual(tracks.map(\.id), ["spotify:track:abc", "spotify:episode:xyz"])
        XCTAssertEqual(tracks[0].artist, "A, B")
        XCTAssertEqual(tracks[0].duration, 201)
        XCTAssertEqual(tracks[0].artworkURL?.absoluteString, "https://i.scdn.co/300")
        XCTAssertEqual(tracks[1].artist, "Podcast")
        XCTAssertTrue(SpotifyResponses.queueTracks(from: Data("nope".utf8)).isEmpty)
    }

    func testParsesLibrarySearch() {
        let raw = "A1B2\u{1F}Song\u{1F}Artist\u{1F}201,5\u{1E}\u{1F}No id\u{1F}X\u{1F}10\u{1E}C3D4\u{1F}Other\u{1F}missing value\u{1F}62"
        let tracks = MusicScriptOutput.tracks(raw)
        XCTAssertEqual(tracks.map(\.id), ["A1B2", "C3D4"])
        XCTAssertEqual(tracks[0].duration, 201)
        XCTAssertEqual(tracks[1].artist, "")
        XCTAssertTrue(MusicScriptOutput.tracks("").isEmpty)
    }

    func testLibrarySearchScriptQuotesTheQuery() {
        let script = MusicScriptOutput.librarySearchScript(#"say "hi" \ bye"#, limit: 5)
        XCTAssertTrue(script.contains(#"search library playlist 1 for "say \"hi\" \\ bye""#))
    }

    func testReadsSpotifySearch() {
        let json = """
        {"tracks":{"items":[
          {"uri":"spotify:track:one","name":"One","duration_ms":120000,"artists":[{"name":"A"}],
           "album":{"images":[{"url":"https://i.scdn.co/640","width":640},{"url":"https://i.scdn.co/300","width":300}]}},
          null,
          {"uri":"spotify:track:two","name":"","artists":[]}
        ]}}
        """
        let tracks = SpotifyResponses.searchTracks(from: Data(json.utf8))
        XCTAssertEqual(tracks.map(\.id), ["spotify:track:one"])
        XCTAssertEqual(tracks[0].artworkURL?.absoluteString, "https://i.scdn.co/300")
        XCTAssertTrue(SpotifyResponses.searchTracks(from: Data(#"{"queue":[]}"#.utf8)).isEmpty)
    }

    func testSpotifySearchRequestPagesByOffset() throws {
        let request = try XCTUnwrap(SpotifyResponses.searchRequest(query: "daft punk & co", offset: 10, token: "t"))
        let items = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "daft punk & co")
        XCTAssertEqual(items.first { $0.name == "type" }?.value, "track")
        XCTAssertEqual(items.first { $0.name == "offset" }?.value, "10")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testSpotifyStatusCodes() {
        XCTAssertNil(SpotifyResponses.failure(status: 204, body: Data()))
        XCTAssertEqual(SpotifyResponses.failure(status: 401, body: Data()), .notSignedIn)
        XCTAssertEqual(SpotifyResponses.failure(status: 403, body: Data()), .premiumRequired)
        XCTAssertEqual(SpotifyResponses.failure(status: 404, body: Data()), .noActiveDevice)
        XCTAssertEqual(SpotifyResponses.failure(status: 500, body: Data(#"{"error":{"status":500,"message":"Oops"}}"#.utf8)), .failed("Oops"))
        XCTAssertEqual(SpotifyResponses.failure(status: 403, body: Data(#"{"error":{"status":403,"message":"Insufficient client scope"}}"#.utf8)), .missingScope)
    }

    // MARK: Spotify playlists

    func testSpotifyPlaylistID() {
        XCTAssertEqual(SpotifyResponses.playlistID("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M"), "37i9dQZF1DXcBWIGoYBM5M")
        XCTAssertNil(SpotifyResponses.playlistID("spotify:track:abc"))
        XCTAssertNil(SpotifyResponses.playlistID("spotify:playlist:../me"))
    }

    func testSpotifyPlaylistsTellOwnFromFollowed() {
        let json = #"""
        {"items":[
          {"uri":"spotify:playlist:mine1","name":"Mine","owner":{"id":"me"},"collaborative":false,
           "items":{"total":12},"images":[{"url":"https://i.scdn.co/640","width":640},{"url":"https://i.scdn.co/300","width":300}]},
          {"uri":"spotify:playlist:theirs","name":"Theirs","owner":{"id":"spotify","display_name":"Spotify"},"tracks":{"total":50},"images":null},
          {"uri":"spotify:playlist:collab","name":"Shared","owner":{"id":"friend"},"collaborative":true,"tracks":{"total":3}},
          null
        ],"next":"https://api.spotify.com/v1/me/playlists?offset=50"}
        """#
        let data = Data(json.utf8)
        let lists = SpotifyResponses.playlists(from: data, userID: "me")
        XCTAssertEqual(lists.map(\.name), ["Mine", "Theirs", "Shared"])
        XCTAssertEqual(lists.map(\.trackCount), [12, 50, 3])
        XCTAssertEqual(lists.map(\.editable), [true, false, true])
        XCTAssertEqual(lists.map(\.owner), ["", "Spotify", "friend"])
        XCTAssertEqual(lists[0].artworkURL?.absoluteString, "https://i.scdn.co/300")
        XCTAssertEqual(SpotifyResponses.nextPage(from: data)?.absoluteString, "https://api.spotify.com/v1/me/playlists?offset=50")
    }

    func testSpotifyPlaylistItemsReadBothShapes() {
        let json = #"""
        {"items":[
          {"item":{"uri":"spotify:track:new","name":"New","duration_ms":1000,"artists":[{"name":"A"}],"album":{"name":"Alb","images":[]}}},
          {"track":{"uri":"spotify:track:old","name":"Old","duration_ms":2000,"artists":[{"name":"B"}]}},
          {"track":{"uri":"spotify:local:x","name":"Local","is_local":true}},
          {"track":null}
        ],"next":null}
        """#
        let tracks = SpotifyResponses.playlistTracks(from: Data(json.utf8))
        XCTAssertEqual(tracks.map(\.id), ["spotify:track:new", "spotify:track:old"])
        XCTAssertEqual(tracks[0].album, "Alb")
        XCTAssertNil(SpotifyResponses.nextPage(from: Data(json.utf8)))
    }

    func testSpotifyJSONRequest() throws {
        let request = SpotifyResponses.request(try XCTUnwrap(URL(string: "https://api.spotify.com/v1/me/playlists")), method: "POST",
                                               json: ["name": "Road"], token: "t")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "Road")
    }
}

final class MusicHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current
        return calendar
    }

    /// Friday 6 November 2026, 20:00.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 20)) ?? Date() }

    private func play(_ id: String, artist: String = "A", listened: Int = 200, daysAgo: Int = 0, hour: Int? = nil) -> MusicPlay {
        var date = calendar.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        if let hour { date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) ?? date }
        return MusicPlay(id: id, title: "T\(id)", artist: artist, app: "Spotify", duration: 200, listened: listened, playedAt: date)
    }

    func testListeningCountsTimeThatSoundedOnly() {
        var listening = MusicListening()
        let start = now
        let song = play("1")
        XCTAssertNil(listening.update(song, isPlaying: true, at: start))
        XCTAssertNil(listening.update(song, isPlaying: false, at: start.addingTimeInterval(20)))
        // Paused for an hour: that does not count.
        XCTAssertNil(listening.update(song, isPlaying: true, at: start.addingTimeInterval(3600)))
        let finished = listening.update(play("2"), isPlaying: true, at: start.addingTimeInterval(3620))
        XCTAssertEqual(finished?.id, "1")
        XCTAssertEqual(finished?.listened, 40)
        XCTAssertEqual(finished?.playedAt, start.addingTimeInterval(3620))
    }

    func testASkippedTrackIsNoPlayAndAShortOneNeedsHalf() {
        var listening = MusicListening()
        _ = listening.update(play("1"), isPlaying: true, at: now)
        XCTAssertNil(listening.update(play("2"), isPlaying: true, at: now.addingTimeInterval(10)))
        XCTAssertTrue(MusicListening.counts(20, duration: 40))
        XCTAssertFalse(MusicListening.counts(19, duration: 40))
        XCTAssertFalse(MusicListening.counts(29, duration: 0))
    }

    func testListeningNeverExceedsTheTrack() {
        var listening = MusicListening()
        _ = listening.update(play("1"), isPlaying: true, at: now)
        XCTAssertEqual(listening.finish(at: now.addingTimeInterval(9000))?.listened, 200)
        XCTAssertNil(listening.finish(at: now.addingTimeInterval(9001)))
    }

    func testMergeSkipsPlaysNookMeasuredItself() {
        var history = MusicHistory()
        history.add(play("1"))
        let same = play("1", listened: 180)
        var moved = same
        moved.playedAt = same.playedAt.addingTimeInterval(120)
        XCTAssertFalse(history.merge(imported: [moved]))
        XCTAssertTrue(history.merge(imported: [play("1", daysAgo: 1), play("2", daysAgo: 2)]))
        XCTAssertFalse(history.merge(imported: [play("2", daysAgo: 2)]))
        XCTAssertEqual(history.plays.map(\.id), ["2", "1", "1"])
    }

    func testSamplePlaysAreDropped() {
        var history = MusicHistory()
        history.add(play("spotify:track:GetLucky"))
        history.add(play("spotify:track:4E63weMCaNZuGPEFMnuEi8"))
        history.add(play("1"))
        XCTAssertTrue(history.dropUnrealPlays())
        XCTAssertEqual(history.plays.map(\.id), ["spotify:track:4E63weMCaNZuGPEFMnuEi8", "1"])
        XCTAssertFalse(history.dropUnrealPlays())
    }

    func testSearchesKeepTheNewestOnce() {
        var history = MusicHistory()
        for index in 0..<12 { history.remember(search: "q\(index)") }
        history.remember(search: " Q11 ")
        XCTAssertEqual(history.searches.first, "Q11")
        XCTAssertEqual(history.searches.count, MusicHistory.searchLimit)
        history.forget(search: "Q11")
        XCTAssertEqual(history.searches.first, "q10")
    }

    func testHistorySurvivesAFile() throws {
        var history = MusicHistory()
        history.add(play("1"))
        history.recent.add(MusicTrack(id: "1", title: "One", artist: "A", duration: 1, artworkURL: URL(string: "https://i.scdn.co/1")))
        history.remember(search: "daft")
        let decoded = try JSONDecoder().decode(MusicHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded, history)
    }

    func testStatsSumAndRankThePeriodOnly() {
        let plays = [
            play("old", artist: "Z", daysAgo: 40), play("1", artist: "B", listened: 100, daysAgo: 8),
            play("1", artist: "A", listened: 300, daysAgo: 2, hour: 22), play("1", artist: "A", listened: 300, daysAgo: 1, hour: 22),
            play("2", artist: "C", listened: 60, daysAgo: 0, hour: 9),
        ]
        let stats = MusicStats(plays: plays, period: .week, now: now, calendar: calendar)
        XCTAssertEqual(stats.plays, 3)
        XCTAssertEqual(stats.seconds, 660)
        XCTAssertEqual(stats.uniqueTracks, 2)
        XCTAssertEqual(stats.uniqueArtists, 2)
        XCTAssertEqual(stats.topTracks.first?.plays, 2)
        XCTAssertEqual(stats.topArtists.first?.name, "A")
        XCTAssertEqual(stats.previousSeconds, 100)
        XCTAssertEqual(stats.change, 560)
        XCTAssertEqual(stats.peakHour, 22)
        XCTAssertEqual(stats.buckets.count, 7)
        XCTAssertEqual(stats.buckets.reduce(0) { $0 + $1.seconds }, 660)
        XCTAssertEqual(stats.buckets.last?.seconds, 60)
        XCTAssertEqual(stats.streak, 3)
    }

    func testStatsPlaceListeningOnTheWeekGridAndCountNewArtists() {
        let plays = [
            play("old", artist: "Z", daysAgo: 40), play("1", artist: "B", listened: 100, daysAgo: 8),
            play("1", artist: "A", listened: 300, daysAgo: 2, hour: 22), play("2", artist: "B", listened: 60, daysAgo: 0, hour: 9),
        ]
        let stats = MusicStats(plays: plays, period: .week, now: now, calendar: calendar)
        let day = { (daysAgo: Int) -> Int in
            let date = self.calendar.date(byAdding: .day, value: -daysAgo, to: self.now)!
            return (self.calendar.component(.weekday, from: date) - self.calendar.firstWeekday + 7) % 7
        }
        XCTAssertEqual(stats.weekHours[day(2)][22], 300)
        XCTAssertEqual(stats.weekHours[day(0)][9], 60)
        XCTAssertEqual(stats.weekHours.flatMap { $0 }.reduce(0, +), stats.seconds)
        // B was played before the week, A was not.
        XCTAssertEqual(stats.newArtists, 1)
        XCTAssertNil(MusicStats(plays: plays, period: .all, now: now, calendar: calendar).newArtists)
    }

    func testStreakToleratesAnUnplayedToday() {
        let stats = MusicStats(plays: [play("1", daysAgo: 3), play("1", daysAgo: 2), play("1", daysAgo: 1)], period: .all, now: now, calendar: calendar)
        XCTAssertEqual(stats.streak, 3)
        XCTAssertEqual(MusicStats(plays: [play("1", daysAgo: 2)], period: .all, now: now, calendar: calendar).streak, 0)
    }

    func testYearHasTwelveMonthsAndAllAtLeastSix() {
        XCTAssertEqual(MusicStats(plays: [], period: .year, now: now, calendar: calendar).buckets.count, 12)
        XCTAssertEqual(MusicStats(plays: [], period: .month, now: now, calendar: calendar).buckets.count, 30)
        XCTAssertEqual(MusicStats(plays: [play("1", daysAgo: 2)], period: .all, now: now, calendar: calendar).buckets.count, 6)
        XCTAssertEqual(MusicStats(plays: [play("1", daysAgo: 1000)], period: .all, now: now, calendar: calendar).buckets.count, 24)
    }

    func testListenerTypeFollowsThePartOfTheDay() {
        let plays = (0..<6).map { play("\($0)", daysAgo: $0, hour: 19 + $0 % 3) } + [play("x", listened: 500, daysAgo: 1, hour: 12)]
        XCTAssertEqual(MusicStats(plays: plays, period: .week, now: now, calendar: calendar).listenerType, .evening)
        XCTAssertNil(MusicStats(plays: [play("1")], period: .week, now: now, calendar: calendar).listenerType)
    }

    func testAPlayerUpFrontStaysAndAHiddenOneGoesBack() {
        let spotify = "com.spotify.client"
        let hidden = MusicPlayerFocus(frontmost: "com.apple.Safari", playerBundleID: spotify, wasOutOfSight: true)
        XCTAssertTrue(hidden.stoleFront(now: spotify))
        XCTAssertFalse(hidden.stoleFront(now: "com.apple.Safari"))
        XCTAssertTrue(hidden.shouldHide)
        let open = MusicPlayerFocus(frontmost: spotify, playerBundleID: spotify, wasOutOfSight: false)
        XCTAssertFalse(open.stoleFront(now: spotify))
        XCTAssertFalse(open.shouldHide)
        XCTAssertFalse(MusicPlayerFocus(frontmost: "com.apple.Safari", playerBundleID: spotify, wasOutOfSight: false).shouldHide)
    }

    func testSpotifyPlayRequestsCarryTheTargetAsJSON() throws {
        let tracks = try XCTUnwrap(SpotifyResponses.playRequest(.tracks(["spotify:track:a", "spotify:track:b"]), token: "t"))
        XCTAssertEqual(tracks.httpMethod, "PUT")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(tracks.httpBody)) as? [String: Any])
        XCTAssertEqual(body["uris"] as? [String], ["spotify:track:a", "spotify:track:b"])
        let context = try XCTUnwrap(SpotifyResponses.playRequest(.context("spotify:playlist:p", offset: "spotify:track:a"), token: "t"))
        let contextBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(context.httpBody)) as? [String: Any])
        XCTAssertEqual(contextBody["context_uri"] as? String, "spotify:playlist:p")
        XCTAssertEqual((contextBody["offset"] as? [String: String])?["uri"], "spotify:track:a")
    }

    func testRecentlyPlayedReadsOldestFirstWithTheFirstArtist() {
        let json = """
        {"items":[
          {"played_at":"2026-11-06T10:00:00.123Z","track":{"uri":"spotify:track:b","name":"B","duration_ms":200000,"artists":[{"name":"X"},{"name":"Y"}],"album":{"name":"Al","images":[]}}},
          {"played_at":"2026-11-05T10:00:00Z","track":{"uri":"spotify:track:a","name":"A","duration_ms":100000,"artists":[{"name":"Z"}],"album":{"name":"Bl","images":[]}}},
          {"played_at":"nonsense","track":{"uri":"spotify:track:c","name":"C"}}
        ]}
        """
        let plays = SpotifyResponses.recentPlays(from: Data(json.utf8))
        XCTAssertEqual(plays.map(\.title), ["A", "B"])
        XCTAssertEqual(plays.last?.artist, "X")
        XCTAssertEqual(plays.last?.listened, 200)
    }

    func testTopArtistsAndLibraryPlayCounts() {
        let artists = SpotifyResponses.topArtists(from: Data(#"{"items":[{"name":"Daft Punk","images":[{"url":"https://i.scdn.co/1","width":320}]}]}"#.utf8))
        XCTAssertEqual(artists.first?.name, "Daft Punk")
        XCTAssertEqual(artists.first?.artworkURL?.absoluteString, "https://i.scdn.co/1")

        let rs = "\u{1E}", fs = "\u{1F}"
        let raw = ["AA\(fs)One\(fs)X\(fs)100\(fs)Al\(fs)3", "BB\(fs)Two\(fs)Y\(fs)100\(fs)Al\(fs)9", "CC\(fs)Three\(fs)X\(fs)100\(fs)Al\(fs)8"].joined(separator: rs)
        let top = MusicScriptOutput.libraryTop(raw)
        XCTAssertEqual(top.tracks.map(\.title), ["Two", "Three", "One"])
        XCTAssertEqual(top.artists.first?.name, "X")
        XCTAssertEqual(top.artists.first?.plays, 11)
        XCTAssertEqual(top.plays["BB"], 9)
    }
}
