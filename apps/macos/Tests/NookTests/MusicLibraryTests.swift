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
}
