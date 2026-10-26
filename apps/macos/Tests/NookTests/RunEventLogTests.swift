import XCTest

/// The append-only timeline log behind `RunStore`: what each save writes, what a reload replays, and the one-time
/// import of the old JSON timelines.
final class RunEventLogTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = URL(fileURLWithPath: try TestData.tempFolder(), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func rows(_ id: UUID) throws -> [RunEventLog.Row] {
        try XCTUnwrap(RunEventLog(url: folder.appendingPathComponent("runs.sqlite"))).rows(id)
    }

    private func event(_ text: String, kind: RunEvent.Kind = .assistant, state: RunEvent.State? = nil) -> RunEvent {
        RunEvent(kind: kind, text: text, state: state, date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    // MARK: Append and reload

    func testEachSaveAppendsOnlyWhatChanged() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        var events = [event("Do it", kind: .user), event("Working"), event("ls", kind: .tool, state: .running)]
        try store.saveEvents(id, events)
        XCTAssertEqual(try rows(id).map(\.kind), [.event, .event, .event])

        // Unchanged: nothing written.
        try store.saveEvents(id, events)
        XCTAssertEqual(try rows(id).count, 3)

        // A streamed answer grows and a tool finishes; one new event arrives.
        events[1].text += " on it"
        events[2].state = .done
        events.append(event("Done"))
        try store.saveEvents(id, events)
        XCTAssertEqual(try rows(id).map(\.kind), [.event, .event, .event, .update, .update, .event])

        let reloaded = RunStore(directory: folder).loadEvents(id)
        XCTAssertEqual(reloaded, events)
    }

    func testRowsAreNeverRewritten() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        var events = (0..<20).map { event("line \($0)") }
        try store.saveEvents(id, events)
        let first = try rows(id)
        for round in 0..<5 {
            events[19].text += " \(round)"
            events.append(event("more \(round)"))
            try store.saveEvents(id, events)
        }
        let later = try rows(id)
        XCTAssertEqual(Array(later.prefix(first.count)), first, "what was written stays exactly as it was")
        XCTAssertEqual(later.map(\.seq), later.map(\.seq).sorted(), "rows are in the order they were written")
        XCTAssertEqual(Set(later.map(\.seq)).count, later.count)
    }

    func testOrderIsKeptAcrossUpdates() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        var events = [event("a"), event("b"), event("c")]
        try store.saveEvents(id, events)
        // The first event changes last: it must stay first.
        events[0].text = "a!"
        try store.saveEvents(id, events)
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id).map(\.text), ["a!", "b", "c"])
    }

    func testImmediateAppendIsNotWrittenTwice() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        let first = event("Do it", kind: .user)
        store.appendEvent(id, first)
        XCTAssertEqual(try rows(id).count, 1, "written right away")
        let second = event("Sure")
        store.appendEventAsync(id, second)
        store.flush()
        try store.saveEvents(id, [first, second])
        XCTAssertEqual(try rows(id).count, 2, "the save finds both already written")
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id).map(\.text), ["Do it", "Sure"])
    }

    func testAStoreThatDidNotReadTheTimelineStillAppendsOnly() throws {
        let id = UUID()
        let events = [event("a"), event("b")]
        try RunStore(directory: folder).saveEvents(id, events)
        // A new launch saves without having loaded the timeline (an event arrived first).
        try RunStore(directory: folder).saveEvents(id, events + [event("c")])
        XCTAssertEqual(try rows(id).map(\.kind), [.event, .event, .event])
    }

    func testTimelinesAreSeparate() throws {
        let store = RunStore(directory: folder)
        let one = UUID()
        let two = UUID()
        try store.saveEvents(one, [event("one")])
        try store.saveEvents(two, [event("two")])
        store.deleteEvents(one)
        XCTAssertEqual(store.loadEvents(one), [])
        XCTAssertEqual(store.loadEvents(two).map(\.text), ["two"])
    }

    // MARK: Snapshots and compaction

    func testRemovedOrReorderedEventsWriteASnapshot() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        let a = event("a"), b = event("b"), c = event("c")
        try store.saveEvents(id, [a, b, c])
        try store.saveEvents(id, [a, c])
        XCTAssertEqual(try rows(id).map(\.kind), [.snapshot], "the snapshot replaces the earlier rows")
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id).map(\.text), ["a", "c"])

        try store.saveEvents(id, [c, a])
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id).map(\.text), ["c", "a"])

        // A new event placed before written ones is a reorder too.
        let d = event("d")
        try store.saveEvents(id, [d, c, a])
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id).map(\.text), ["d", "c", "a"])

        try store.saveEvents(id, [])
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id), [])
    }

    func testALongLogIsCompactedOnLoad() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        var events = [event("question", kind: .user), event("")]
        for step in 0..<RunStore.compactionMinimumRows {
            events[1].text += "\(step) "
            try store.saveEvents(id, events)
        }
        XCTAssertGreaterThan(try rows(id).count, RunStore.compactionMinimumRows)
        let loaded = RunStore(directory: folder).loadEvents(id)
        XCTAssertEqual(loaded, events)
        XCTAssertEqual(try rows(id).map(\.kind), [.snapshot])
        XCTAssertEqual(RunStore(directory: folder).loadEvents(id), events, "the compacted log reads the same")
    }

    func testUnreadableRowsAreSkippedAndKept() throws {
        let store = RunStore(directory: folder)
        let id = UUID()
        let a = event("a")
        try store.saveEvents(id, [a])
        let log = try XCTUnwrap(RunEventLog(url: store.databaseURL))
        log.append(id, .event, Data("{\"from\":\"a newer version\"}".utf8))
        try store.saveEvents(id, [a])
        let other = RunStore(directory: folder)
        XCTAssertEqual(other.loadEvents(id).map(\.text), ["a"])
        try other.saveEvents(id, other.loadEvents(id) + [event("b")])
        XCTAssertEqual(try rows(id).count, 3, "the unreadable row stays: it is not compacted away")
    }

    // MARK: Fold

    func testFoldRules() throws {
        let id = UUID()
        let a = event("a"), b = event("b")
        var a2 = a
        a2.text = "a2"
        func row(_ seq: Int64, _ kind: RunEventLog.Kind, _ value: some Encodable) throws -> RunEventLog.Row {
            RunEventLog.Row(seq: seq, runID: id, kind: kind, payload: try Self.encoder.encode(value), at: Date())
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let result = RunEventFold.fold([
            try row(1, .event, a), try row(2, .event, b), try row(3, .update, a2),
            // An update for an event the log never saw is kept, at the end.
            try row(4, .update, event("orphan"))
        ], decoder: decoder)
        XCTAssertEqual(result.events.map(\.text), ["a2", "b", "orphan"])
        XCTAssertEqual(result.supersededRows, 1)

        let reset = RunEventFold.fold([try row(1, .event, a), try row(2, .snapshot, [b]), try row(3, .event, a2)], decoder: decoder)
        XCTAssertEqual(reset.events.map(\.text), ["b", "a2"], "a snapshot replaces everything before it")
    }

    // MARK: Import of the JSON timelines

    func testJSONTimelinesAreImportedOnceAndKept() throws {
        let id = UUID()
        let events = [event("old question", kind: .user), event("old answer"), event("tool", kind: .tool, state: .running)]
        let legacy = folder.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let file = legacy.appendingPathComponent(id.uuidString + ".json")
        try Self.encoder.encode(events).write(to: file)
        try Data("not a timeline".utf8).write(to: legacy.appendingPathComponent("notes.txt"))

        let store = RunStore(directory: folder)
        XCTAssertEqual(store.loadRuns(), [])
        let loaded = store.loadEvents(id)
        XCTAssertEqual(loaded.map(\.text), events.map(\.text))
        XCTAssertEqual(loaded[2].state, .failed, "a running tool is no longer running after the import either")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the JSON file stays as a backup")
        XCTAssertEqual(try rows(id).map(\.kind), [.snapshot])

        // Saving after the import appends to it; the next launch does not import again.
        try store.saveEvents(id, loaded + [event("new")])
        let again = RunStore(directory: folder)
        XCTAssertEqual(again.loadEvents(id).map(\.text), events.map(\.text) + ["new"])
        XCTAssertEqual(try rows(id).count, 3, "snapshot, the tool that is no longer running, the new event")

        // Deleting the session removes the backup too.
        again.deleteEvents(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDamagedJSONTimelineIsKeptAsideAndSkipped() throws {
        let id = UUID()
        let legacy = folder.appendingPathComponent("events", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: legacy.appendingPathComponent(id.uuidString + ".json"))
        let store = RunStore(directory: folder)
        XCTAssertEqual(store.loadEvents(id), [])
        let files = try FileManager.default.contentsOfDirectory(atPath: legacy.path)
        XCTAssertTrue(files.contains { $0.contains(".unreadable-") }, "the damaged file is copied aside, as before")
    }

    // MARK: Storage

    func testDatabaseIsPrivateAndUsesWAL() throws {
        let store = RunStore(directory: folder)
        try store.saveEvents(UUID(), [event("a")])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.databaseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let log = try XCTUnwrap(RunEventLog(url: store.databaseURL))
        XCTAssertEqual(log.schemaVersion, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.databaseURL.path + "-wal"), "write-ahead log")
    }

    func testUnopenableDatabaseFailsSavesWithoutCrashing() throws {
        // A folder where the database file should be: SQLite cannot open it.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("runs.sqlite"), withIntermediateDirectories: true)
        let store = RunStore(directory: folder)
        XCTAssertThrowsError(try store.saveEvents(UUID(), [event("a")]))
        XCTAssertEqual(store.loadEvents(UUID()), [])
    }
}
