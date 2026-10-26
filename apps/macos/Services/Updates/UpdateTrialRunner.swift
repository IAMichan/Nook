import Foundation

/// Runs an update's trial (`UpdateTrial`) around Nook's launch. main.swift calls `atLaunch` before anything opens the
/// database: a new build whose last launch crashed before it proved healthy is rolled back there (the previous app and
/// the database snapshot put back, the previous app started, this process gone). Once Nook runs, `startWatching`
/// commits the trial after a healthy minute; a normal quit is not counted as a crash (`cleanExit`).
///
/// It cannot help a build that crashes before main.swift runs (a missing library): that one needs the previous version
/// downloaded by hand.
enum UpdateTrialRunner {
    private static var folder: URL { NookPaths.supportDirectory.appendingPathComponent("Rollback", isDirectory: true) }
    static var recordURL: URL { NookPaths.supportDirectory.appendingPathComponent("update-trial.json") }
    /// Where an update keeps the previous app until the new one is committed.
    static var keptAppURL: URL { folder.appendingPathComponent("Nook.app", isDirectory: true) }
    /// Where the relaunch copies the database before the new build first starts.
    static var snapshotURL: URL { folder.appendingPathComponent("database", isDirectory: true) }

    /// This build as a trial names it: its commit, or its release version. Nil for a build that cannot update.
    static var currentBuild: String? {
        let info = Bundle.main.infoDictionary ?? [:]
        return BuildSource(info: info)?.commit ?? ReleaseBuild(info: info)?.version.description
    }

    /// A rollback this (previous) build was put back by, to tell the user once Nook runs.
    private(set) static var rollbackToReport: UpdateTrial?
    /// This launch is a new build on trial.
    private static var watching = false

    /// First thing at launch. Does not return when it rolls back: the previous app starts once this process is gone.
    static func atLaunch() {
        guard let build = currentBuild else { return }
        let (next, action) = UpdateTrialMachine.launch(UpdateTrialStore.load(recordURL), build: build)
        UpdateTrialStore.save(next, to: recordURL)
        switch action {
        case .none: break
        case .watch: watching = true
        case .cleanUp(let trial): UpdateRollback.cleanUp(trial)
        case .reportRollback(let trial): rollbackToReport = trial
        case .restore(let trial): restore(trial)
        }
    }

    private static func restore(_ trial: UpdateTrial) {
        do {
            try UpdateRollback.restore(trial, database: NookPaths.databaseURL)
        } catch {
            // Nothing to go back to: run this build rather than none, and do not try again on every launch.
            NSLog("Nook: rolling back the update failed: %@", error.localizedDescription)
            UpdateTrialStore.save(nil, to: recordURL)
            return
        }
        UpdateTrialStore.save(UpdateTrialMachine.restored(trial), to: recordURL)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = Relaunch.arguments(pid: ProcessInfo.processInfo.processIdentifier, appPath: trial.appPath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        exit(0)
    }

    /// Commits the trial after `UpdateTrialMachine.healthyAfter` of normal running.
    @MainActor
    static func startWatching() {
        guard watching else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + UpdateTrialMachine.healthyAfter) {
            guard watching, let build = currentBuild else { return }
            watching = false
            let (next, action) = UpdateTrialMachine.healthy(UpdateTrialStore.load(recordURL), build: build)
            UpdateTrialStore.save(next, to: recordURL)
            if case .cleanUp(let trial) = action { UpdateRollback.cleanUp(trial) }
        }
    }

    /// Nook quits normally while on trial: this launch did not crash.
    static func cleanExit() {
        guard watching, let build = currentBuild else { return }
        UpdateTrialStore.save(UpdateTrialMachine.cleanExit(UpdateTrialStore.load(recordURL), build: build), to: recordURL)
    }

    /// An update put a new build at `appPath` and kept the previous one at `keptAppURL`: the new build is on trial from
    /// its first launch.
    static func begin(from: String, to: String, appPath: String) {
        try? FileManager.default.removeItem(at: snapshotURL)
        let trial = UpdateTrial(from: from, to: to, appPath: appPath, previousApp: keptAppURL.path, snapshot: snapshotURL.path,
                                installedAt: Date())
        UpdateTrialStore.save(trial, to: recordURL)
    }

    /// The relaunch into an update: it also takes the database snapshot while a trial waits for its first launch.
    static func relaunchArguments(pid: Int32, appPath: String) -> [String] {
        if let trial = UpdateTrialStore.load(recordURL), trial.stage == .trial, !trial.running, trial.failedLaunches == 0,
           let snapshot = trial.snapshot {
            return Relaunch.arguments(pid: pid, appPath: appPath, database: NookPaths.databaseURL.path, snapshot: snapshot)
        }
        return Relaunch.arguments(pid: pid, appPath: appPath)
    }
}
