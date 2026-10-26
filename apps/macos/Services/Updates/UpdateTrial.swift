import Foundation

// A new build of Nook is on trial until it proves it runs (trial, then commit): before the update replaces the app, the
// previous app is kept, and while the old process is gone the relaunch takes a snapshot of nook.sqlite (with its -wal
// and -shm). The new build marks itself healthy after a minute of normal running. When a launch of the new build ends in
// a crash before that, the next launch puts the previous app and the database back, starts the previous app, and that
// one tells you. Foundation only: the decisions and the file moves are tested on Linux; `UpdateTrialRunner` drives them.

struct UpdateTrial: Codable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        /// Installed; the new build has not proved it runs yet.
        case trial
        /// Putting the previous app and database back. Whichever build starts next finishes it, so a restore that was
        /// interrupted is completed before either version runs.
        case restoring
        /// Rolled back: the previous build says so once.
        case rolledBack
    }

    var stage: Stage = .trial
    /// The build that installed the update and the build it installed: a commit, or a release version.
    var from: String
    var to: String
    /// Where Nook runs.
    var appPath: String
    /// The previous app, kept until the new one is committed.
    var previousApp: String
    /// The folder with the database as it was before the new build first started; nil when there was none to take.
    var snapshot: String?
    var installedAt: Date
    /// Launches of the new build that crashed before it proved healthy.
    var failedLaunches = 0
    /// A launch of the new build runs now: set when it starts, cleared when it proves healthy or quits normally. Still
    /// set at the next launch means that launch crashed.
    var running = false
}

/// What a launch, a healthy minute or a restore asks for.
enum UpdateTrialAction: Equatable, Sendable {
    case none
    /// Run normally and report `healthy` after `UpdateTrialMachine.healthyAfter`.
    case watch
    /// The trial is over (committed, or no longer this build's): remove the kept app and the snapshot.
    case cleanUp(UpdateTrial)
    /// Put the previous app and database back, start the previous app, quit.
    case restore(UpdateTrial)
    /// This is the previous build, put back: tell the user.
    case reportRollback(UpdateTrial)
}

enum UpdateTrialMachine {
    /// Running this long without a crash proves a build healthy.
    static let healthyAfter: TimeInterval = 60
    /// Crashed launches before Nook gives up on the new build.
    static let maxFailedLaunches = 1

    /// At launch, before anything opens the database. Returns the record to keep (nil: remove it) and what to do.
    static func launch(_ trial: UpdateTrial?, build: String) -> (UpdateTrial?, UpdateTrialAction) {
        guard var trial else { return (nil, .none) }
        switch trial.stage {
        case .restoring:
            return (trial, .restore(trial))
        case .rolledBack:
            return (nil, build == trial.from ? .reportRollback(trial) : .none)
        case .trial:
            // The previous build started (put back by hand): its own app must not be removed.
            if build == trial.from { return (nil, .none) }
            // Some other build replaced the new one: the trial is moot.
            guard build == trial.to else { return (nil, .cleanUp(trial)) }
            if trial.running { trial.failedLaunches += 1 }
            if trial.failedLaunches >= maxFailedLaunches {
                trial.stage = .restoring
                trial.running = false
                return (trial, .restore(trial))
            }
            trial.running = true
            return (trial, .watch)
        }
    }

    /// The new build ran `healthyAfter` without a crash: it is committed.
    static func healthy(_ trial: UpdateTrial?, build: String) -> (UpdateTrial?, UpdateTrialAction) {
        guard let trial, trial.stage == .trial, trial.to == build else { return (trial, .none) }
        return (nil, .cleanUp(trial))
    }

    /// Nook quits normally during the trial: that launch did not crash.
    static func cleanExit(_ trial: UpdateTrial?, build: String) -> UpdateTrial? {
        guard var trial, trial.stage == .trial, trial.to == build else { return trial }
        trial.running = false
        return trial
    }

    /// The files are back: the previous build reports it when it starts.
    static func restored(_ trial: UpdateTrial) -> UpdateTrial {
        var done = trial
        done.stage = .rolledBack
        return done
    }
}

/// The trial record on disk (Application Support/Nook/update-trial.json), written atomically.
enum UpdateTrialStore {
    static func load(_ url: URL) -> UpdateTrial? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateTrial.self, from: data)
    }

    /// nil removes the record.
    static func save(_ trial: UpdateTrial?, to url: URL) {
        guard let trial else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(trial) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

/// The files of a trial: where the previous app and the snapshot are kept, putting them back, and removing them.
enum UpdateRollback {
    /// The database and its companions, as SQLite keeps them next to each other.
    static func databaseFiles(_ database: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: database.path + $0) }
    }

    /// Puts the snapshot of the database back and the previous app in place of the new one. The database goes first: a
    /// restore interrupted after it is simply run again. The snapshot must hold the main file, or the database is left
    /// alone (a database without its snapshot is better than none).
    static func restore(_ trial: UpdateTrial, database: URL) throws {
        let fileManager = FileManager.default
        if let snapshot = trial.snapshot {
            let folder = URL(fileURLWithPath: snapshot, isDirectory: true)
            let saved = databaseFiles(folder.appendingPathComponent(database.lastPathComponent))
            if fileManager.fileExists(atPath: saved[0].path) {
                for (current, copy) in zip(databaseFiles(database), saved) {
                    try? fileManager.removeItem(at: current)
                    if fileManager.fileExists(atPath: copy.path) { try fileManager.copyItem(at: copy, to: current) }
                }
            }
        }
        let app = URL(fileURLWithPath: trial.appPath)
        let previous = URL(fileURLWithPath: trial.previousApp)
        // Already back (an interrupted restore that got this far).
        guard fileManager.fileExists(atPath: previous.path) else { return }
        let failed = app.deletingLastPathComponent().appendingPathComponent(".\(app.lastPathComponent).failed")
        try? fileManager.removeItem(at: failed)
        let hadApp = fileManager.fileExists(atPath: app.path)
        if hadApp { try fileManager.moveItem(at: app, to: failed) }
        do {
            try fileManager.moveItem(at: previous, to: app)
        } catch {
            if hadApp { try? fileManager.moveItem(at: failed, to: app) }
            throw error
        }
        try? fileManager.removeItem(at: failed)
    }

    /// The trial is over: the kept app and the snapshot go.
    static func cleanUp(_ trial: UpdateTrial) {
        // Never the app that runs.
        guard trial.previousApp != trial.appPath else { return }
        try? FileManager.default.removeItem(atPath: trial.previousApp)
        if let snapshot = trial.snapshot { try? FileManager.default.removeItem(atPath: snapshot) }
    }
}
