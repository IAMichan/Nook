import XCTest

/// An update on trial: a new build that crashes before it proves healthy is rolled back to the previous app and database.
final class UpdateTrialTests: XCTestCase {
    private func trial(_ stage: UpdateTrial.Stage = .trial, running: Bool = false, failed: Int = 0) -> UpdateTrial {
        UpdateTrial(stage: stage, from: "0.2.0", to: "0.3.0", appPath: "/Applications/Nook.app",
                    previousApp: "/kept/Nook.app", snapshot: "/kept/database", installedAt: Date(timeIntervalSince1970: 1_000),
                    failedLaunches: failed, running: running)
    }

    func testFirstLaunchOfTheNewBuildIsWatched() {
        let (next, action) = UpdateTrialMachine.launch(trial(), build: "0.3.0")
        XCTAssertEqual(action, .watch)
        XCTAssertEqual(next?.running, true)
        XCTAssertEqual(next?.failedLaunches, 0)
        XCTAssertEqual(UpdateTrialMachine.launch(nil, build: "0.3.0").1, .none)
    }

    func testAHealthyMinuteCommits() {
        let (watched, _) = UpdateTrialMachine.launch(trial(), build: "0.3.0")
        let (next, action) = UpdateTrialMachine.healthy(watched, build: "0.3.0")
        XCTAssertNil(next, "the record goes")
        XCTAssertEqual(action, .cleanUp(watched!))
        XCTAssertEqual(UpdateTrialMachine.healthy(trial(.rolledBack), build: "0.3.0").1, .none)
        XCTAssertEqual(UpdateTrialMachine.healthy(trial(), build: "0.4.0").1, .none, "another build proves nothing")
    }

    func testACleanQuitIsNotACrash() {
        let (watched, _) = UpdateTrialMachine.launch(trial(), build: "0.3.0")
        let quit = UpdateTrialMachine.cleanExit(watched, build: "0.3.0")
        XCTAssertEqual(quit?.running, false)
        let (again, action) = UpdateTrialMachine.launch(quit, build: "0.3.0")
        XCTAssertEqual(action, .watch)
        XCTAssertEqual(again?.failedLaunches, 0)
    }

    func testACrashedLaunchRollsBackAndThePreviousBuildTells() {
        let (watched, _) = UpdateTrialMachine.launch(trial(), build: "0.3.0")
        // It crashed: `running` is still set at the next launch.
        let (restoring, action) = UpdateTrialMachine.launch(watched, build: "0.3.0")
        XCTAssertEqual(restoring?.stage, .restoring)
        XCTAssertEqual(restoring?.failedLaunches, UpdateTrialMachine.maxFailedLaunches)
        guard case .restore = action else { return XCTFail("\(action)") }

        // An interrupted restore is finished by whichever build starts next.
        XCTAssertEqual(UpdateTrialMachine.launch(restoring, build: "0.3.0").1, .restore(restoring!))
        XCTAssertEqual(UpdateTrialMachine.launch(restoring, build: "0.2.0").1, .restore(restoring!))

        let done = UpdateTrialMachine.restored(restoring!)
        let (record, report) = UpdateTrialMachine.launch(done, build: "0.2.0")
        XCTAssertNil(record)
        XCTAssertEqual(report, .reportRollback(done))
        XCTAssertEqual(UpdateTrialMachine.launch(done, build: "0.4.0").1, .none)
    }

    func testOtherBuildsEndTheTrial() {
        let (record, action) = UpdateTrialMachine.launch(trial(running: true), build: "0.4.0")
        XCTAssertNil(record)
        XCTAssertEqual(action, .cleanUp(trial(running: true)), "replaced by yet another build")
        XCTAssertEqual(UpdateTrialMachine.launch(trial(running: true), build: "0.2.0").1, .none,
                       "the previous build started by hand: never remove the app it may run from")
    }

    func testRecordSurvivesARoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("update-trial.json")
        XCTAssertNil(UpdateTrialStore.load(url))
        UpdateTrialStore.save(trial(running: true, failed: 1), to: url)
        XCTAssertEqual(UpdateTrialStore.load(url), trial(running: true, failed: 1))
        UpdateTrialStore.save(nil, to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRestorePutsTheAppAndDatabaseBack() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("rollback-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let apps = root.appendingPathComponent("Applications"), kept = root.appendingPathComponent("Rollback")
        let support = root.appendingPathComponent("Support"), snapshot = kept.appendingPathComponent("database")
        for folder in [apps, kept, support, snapshot] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
        func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

        let app = apps.appendingPathComponent("Nook.app"), previous = kept.appendingPathComponent("Nook.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        try write("new", app.appendingPathComponent("version"))
        try write("old", previous.appendingPathComponent("version"))
        let database = support.appendingPathComponent("nook.sqlite")
        try write("migrated", database)
        try write("new wal", URL(fileURLWithPath: database.path + "-wal"))
        try write("before", snapshot.appendingPathComponent("nook.sqlite"))

        let record = UpdateTrial(stage: .restoring, from: "a", to: "b", appPath: app.path, previousApp: previous.path,
                                 snapshot: snapshot.path, installedAt: Date())
        try UpdateRollback.restore(record, database: database)
        XCTAssertEqual(read(app.appendingPathComponent("version")), "old")
        XCTAssertFalse(fm.fileExists(atPath: previous.path))
        XCTAssertFalse(fm.fileExists(atPath: apps.appendingPathComponent(".Nook.app.failed").path))
        XCTAssertEqual(read(database), "before")
        XCTAssertFalse(fm.fileExists(atPath: database.path + "-wal"), "the new build's WAL must not replay onto the old file")

        // Running it again (an interrupted restore) changes nothing.
        try UpdateRollback.restore(record, database: database)
        XCTAssertEqual(read(app.appendingPathComponent("version")), "old")

        // Without a snapshot of the main file, the database is left alone.
        try write("kept", database)
        let noSnapshot = UpdateTrial(stage: .restoring, from: "a", to: "b", appPath: app.path, previousApp: previous.path,
                                     snapshot: root.appendingPathComponent("missing").path, installedAt: Date())
        try UpdateRollback.restore(noSnapshot, database: database)
        XCTAssertEqual(read(database), "kept")

        try fm.createDirectory(at: previous, withIntermediateDirectories: true)
        UpdateRollback.cleanUp(record)
        XCTAssertFalse(fm.fileExists(atPath: previous.path))
        XCTAssertFalse(fm.fileExists(atPath: snapshot.path))
        XCTAssertTrue(fm.fileExists(atPath: app.path), "never the app that runs")
    }

    func testRelaunchTakesTheSnapshotOnceNookIsGone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("relaunch-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let database = root.appendingPathComponent("nook.sqlite")
        try Data("db".utf8).write(to: database)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: database.path + "-wal"))
        let snapshot = root.appendingPathComponent("snap with space")

        let arguments = Relaunch.arguments(pid: 4242, appPath: "/Applications/Nook.app", database: database.path, snapshot: snapshot.path)
        XCTAssertEqual(Array(arguments.suffix(4)), ["4242", "/Applications/Nook.app", database.path, snapshot.path])
        XCTAssertFalse(Relaunch.script.contains(database.path))

        // A process that already ended: the script copies at once (opening the app fails here, which is fine).
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/bin/sh")
        finished.arguments = ["-c", "exit 0"]
        try finished.run()
        finished.waitUntilExit()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Relaunch.arguments(pid: finished.processIdentifier, appPath: root.appendingPathComponent("none.app").path,
                                               database: database.path, snapshot: snapshot.path)
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(try? Data(contentsOf: snapshot.appendingPathComponent("nook.sqlite")), Data("db".utf8))
        XCTAssertEqual(try? Data(contentsOf: snapshot.appendingPathComponent("nook.sqlite-wal")), Data("wal".utf8))
        XCTAssertFalse(fm.fileExists(atPath: snapshot.appendingPathComponent("nook.sqlite-shm").path))
    }
}
