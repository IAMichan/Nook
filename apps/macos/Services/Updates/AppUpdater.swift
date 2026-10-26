import Foundation
import AppKit
import Combine

/// Keeps Nook in step with main. Nook is built from its own git checkout, so an update is a pull request that was merged
/// since this build: the build wrote its commit into Info.plist (`BuildSource`), and every half hour (and after the Mac
/// wakes) the updater fetches main and counts what came in. The panel footer then shows an update button; installing is
/// always your click and goes: fetch → fast-forward the checkout → xcodegen → xcodebuild (same configuration and Xcode
/// as this build) → put the new app where this one runs → restart. Run from Xcode, it stops after xcodegen and lets you
/// start the new build in Xcode instead, so it runs under the debugger again. Each step is logged to
/// ~/Library/Logs/Nook, and the install is written to the action log.
/// A downloaded build (the release .dmg or .zip) has no checkout: it asks GitHub Releases for a newer version instead
/// (`ReleaseBuild`), and an install downloads the release's .zip, checks its Ed25519 signature, unpacks it and puts the
/// app in place, behind the same button.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    enum Phase: Equatable {
        /// Not built from a checkout nor by the release workflow (or git is missing): no update button anywhere.
        case unavailable
        case idle
        case checking
        case upToDate
        case available
        case installing(UpdateStep)
        /// Built and in place; waiting for you to restart because sessions Nook runs are still working.
        case readyToRestart
        /// Run from Xcode: the checkout is on main and the project generated; Xcode builds and runs the new version.
        case readyToBuildInXcode
        case failed(UpdateFailure)
    }

    /// What main has that this build does not.
    struct Available: Equatable, Sendable {
        let repository: String
        let remote: String
        let branch: String
        let target: String
        /// Commits on main since this build (merges count once).
        let count: Int
        /// The newest first, at most 60.
        let changes: [IncomingChange]
        let github: GitHubRepository?
        let checkout: UpdateCheckout

        var preflight: UpdatePreflight { UpdatePreflight.check(checkout) }
        var shortTarget: String { String(target.prefix(7)) }
    }

    /// A newer release a downloaded build cannot install by itself (no signature, or no key in this build to check
    /// one): Settings links to it, nothing installs it.
    struct ManualRelease: Equatable, Sendable {
        let version: ReleaseVersion
        let page: URL?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var available: Available?
    /// What a downloaded build can install (`release`), the counterpart of `available`.
    @Published private(set) var releaseUpdate: ReleaseCandidate?
    @Published private(set) var manualRelease: ManualRelease?
    @Published private(set) var lastChecked: Date?
    /// Why the last check did not get an answer (offline, no remote …); shown in Settings, never as a button.
    @Published private(set) var checkProblem: String?
    @Published private(set) var activity: BuildActivity?
    @Published private(set) var compiledFiles = 0
    @Published private(set) var installStarted: Date?
    /// The update this build came from, shown once after the restart.
    @Published private(set) var receipt: UpdateReceipt?
    /// You opened the panel for the update that is available now; a newer one makes the button pulse again.
    @Published var seen = false
    /// The menu bar or Settings asked the footer to open the panel.
    @Published var panelRequested = false
    @Published var autoCheck: Bool {
        didSet {
            UserDefaults.standard.set(autoCheck, forKey: Self.autoCheckKey)
            schedule()
        }
    }

    let source: BuildSource?
    /// A downloaded build made by the release workflow; only used when there is no `source`.
    let release: ReleaseBuild?
    /// Xcode launched this process: an update ends with a build in Xcode instead of one of its own and a restart.
    let fromXcode: Bool
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var checking = false
    private var installation: Installation?
    /// A release install's own task, so cancelling stops a download too.
    private var releaseTask: Task<Void, Never>?

    private static let autoCheckKey = "nook.updates.autoCheck"
    private static let receiptKey = "nook.updates.receipt"
    private static let interval: TimeInterval = 30 * 60
    /// The footer asks for a check when it appears, at most this often.
    private static let staleAfter: TimeInterval = 10 * 60

    init(source: BuildSource? = Bundle.main.infoDictionary.flatMap(BuildSource.init(info:)),
         release: ReleaseBuild? = Bundle.main.infoDictionary.flatMap(ReleaseBuild.init(info:)),
         fromXcode: Bool = BuildSource.launchedByXcode(ProcessInfo.processInfo.environment)) {
        self.source = source
        self.release = source == nil ? release : nil
        self.fromXcode = fromXcode
        self.autoCheck = UserDefaults.standard.object(forKey: Self.autoCheckKey) as? Bool ?? true
        if source == nil, release == nil { phase = .unavailable }
    }

    /// This is a downloaded build: updates come from GitHub Releases.
    var isReleaseBuild: Bool { release != nil }

    /// The steps the panel lists for an install.
    var steps: [UpdateStep] { UpdateStep.sequence(release: isReleaseBuild, fromXcode: fromXcode) }

    /// Something to install, from either kind of build.
    var hasUpdate: Bool { available != nil || releaseUpdate != nil }

    // MARK: Checking

    func start() {
        if let source {
            loadReceipt(for: source.commit)
        } else if let release {
            loadReceipt(for: release.version.description)
        } else {
            phase = .unavailable
            return
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // The network needs a moment after waking.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.autoCheck else { return }
                self.check()
            }
        }
        schedule()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard self.autoCheck else { return }
            self.check()
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard autoCheck, source != nil || release != nil else { return }
        timer = Timer.scheduledCoalesced(withTimeInterval: Self.interval) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }

    /// A check when the last one is a while ago: the footer calls this when it appears.
    func checkIfStale() {
        guard autoCheck else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.staleAfter { return }
        check()
    }

    /// Fetches main and works out what is new. Never while installing; quiet when it fails (a later check tries again).
    func check() {
        if source == nil, let release {
            checkRelease(release)
            return
        }
        guard let source, !checking, !isBusy, phase != .unavailable else { return }
        checking = true
        if available == nil, !isFailed { phase = .checking }
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { () -> Result<Available?, Error> in
                Result<Available?, Error> {
                    // Resolving git spawns it once: never on the main thread.
                    guard let git = GitService.shared else { throw GitError(tr("update.problem.noGit")) }
                    return try Self.inspect(source, git: git)
                }
            }.value
            checking = false
            lastChecked = Date()
            switch result {
            case .success(let update):
                checkProblem = nil
                if update?.target != available?.target { seen = false }
                available = update
                if update != nil, receipt != nil { receipt = nil }
                // A failed install keeps its message until you try again or close it, and an install you started
                // while this check ran keeps its steps.
                if !isFailed, !isBusy { phase = update == nil ? .upToDate : .available }
            case .failure(let error):
                checkProblem = error.localizedDescription
                if !isFailed, !isBusy { phase = available == nil ? .idle : .available }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// An install runs or waits for its restart (or build in Xcode): a check must not take the phase back.
    private var isBusy: Bool {
        switch phase {
        case .installing, .readyToRestart, .readyToBuildInXcode: return true
        default: return installation != nil
        }
    }

    /// Asks GitHub for the releases and picks the newest this downloaded build can take. Quiet when it fails, like `check`.
    private func checkRelease(_ release: ReleaseBuild) {
        guard !checking, !isBusy, let url = release.releasesURL else { return }
        checking = true
        if releaseUpdate == nil, !isFailed { phase = .checking }
        Task { @MainActor in
            let result: Result<ReleaseCheck, Error>
            do {
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("Nook/\(release.version)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw NookError(tr("update.release.problem.status", status)) }
                result = .success(ReleaseSelection.check(GitHubRelease.list(from: data), for: release))
            } catch {
                result = .failure(error)
            }
            checking = false
            lastChecked = Date()
            switch result {
            case .success(let found):
                checkProblem = nil
                var candidate: ReleaseCandidate?
                manualRelease = nil
                switch found {
                case .upToDate: break
                case .available(let next): candidate = next
                case .unsigned(let version, let page): manualRelease = ManualRelease(version: version, page: page)
                }
                if candidate?.version != releaseUpdate?.version { seen = false }
                releaseUpdate = candidate
                if candidate != nil, receipt != nil { receipt = nil }
                if !isFailed, !isBusy { phase = candidate == nil ? .upToDate : .available }
            case .failure(let error):
                checkProblem = error.localizedDescription
                if !isFailed, !isBusy { phase = releaseUpdate == nil ? .idle : .available }
            }
        }
    }

    /// Reads the checkout off the main thread. Nil when main has nothing this build lacks.
    nonisolated static func inspect(_ source: BuildSource, git: GitService) throws -> Available? {
        guard let repository = git.repositoryRoot(for: source.projectDirectory) else {
            throw GitError(tr("update.problem.noCheckout", source.projectDirectory))
        }
        let remotes = try git.run(["remote"], in: repository).split(whereSeparator: \.isNewline).map(String.init)
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            throw GitError(tr("update.problem.noRemote"))
        }
        let branch = defaultBranch(of: remote, in: repository, git: git)
        try git.run(["fetch", "--quiet", "--no-tags", remote, branch], in: repository, timeout: 120)
        let target = try git.run(["rev-parse", "--verify", "\(remote)/\(branch)^{commit}"], in: repository).trimmed
        // The build's commit can be gone (a rebased branch that was cleaned up): compare with the checkout then.
        let known = (try? git.run(["cat-file", "-e", source.commit + "^{commit}"], in: repository)) != nil
        let base = try known ? source.commit : git.run(["rev-parse", "HEAD"], in: repository).trimmed
        let count = Int(try git.run(["rev-list", "--count", "--first-parent", "\(base)..\(target)"], in: repository).trimmed) ?? 0
        guard count > 0 else { return nil }
        let log = try git.run(["log", "--first-parent", "--max-count=60", "--format=" + UpdateLog.format, "\(base)..\(target)"],
                              in: repository)
        let remoteURL = (try? git.run(["remote", "get-url", remote], in: repository))?.trimmed ?? ""
        return Available(repository: repository, remote: remote, branch: branch, target: target, count: count,
                         changes: UpdateLog.parse(log), github: GitHubRepository(remoteURL: remoteURL),
                         checkout: try readCheckout(repository, remote: remote, branch: branch, target: target, git: git))
    }

    /// origin/HEAD says which branch is the default one; main when it was never set.
    nonisolated private static func defaultBranch(of remote: String, in repository: String, git: GitService) -> String {
        guard let head = (try? git.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"], in: repository))?.trimmed,
              head.hasPrefix(remote + "/") else { return "main" }
        let branch = String(head.dropFirst(remote.count + 1))
        return branch.isEmpty ? "main" : branch
    }

    nonisolated private static func readCheckout(_ repository: String, remote: String, branch: String, target: String,
                                             git: GitService) throws -> UpdateCheckout {
        let status = try git.run(["status", "--porcelain"], in: repository).split(whereSeparator: \.isNewline).map(String.init)
        let head = try git.run(["rev-parse", "HEAD"], in: repository).trimmed
        let local = Int(try git.run(["rev-list", "--count", "\(target)..HEAD"], in: repository).trimmed) ?? 0
        return UpdateCheckout(branch: git.currentBranch(repository), updateBranch: branch, changedFiles: status,
                              localCommits: local, atTarget: head == target)
    }

    // MARK: Installing

    /// Starts the install you confirmed. `stash`: you agreed to set uncommitted changes aside and put them back after.
    func install(stash: Bool = false) {
        if source == nil, let release, let candidate = releaseUpdate {
            installRelease(candidate, over: release)
            return
        }
        guard let source, let git = GitService.shared, let update = available, installation == nil else { return }
        let installation: Installation
        do {
            installation = try Installation()
        } catch {
            phase = .failed(UpdateFailure(step: .fetch, reason: .other(error.localizedDescription), errors: [], logPath: nil))
            return
        }
        self.installation = installation
        installStarted = Date()
        compiledFiles = 0
        activity = nil
        phase = .installing(.fetch)
        AppModel.shared.store.audit(tool: "app_update", args: "\(source.shortCommit) → \(update.shortTarget)", result: "started")

        let job = Job(source: source, update: update, git: git, allowStash: stash, buildInXcode: fromXcode,
                      environment: UpdateEnvironment.make(base: ProcessInfo.processInfo.environment,
                                                          developerDirectory: source.developerDirectory.flatMap {
                                                              FileManager.default.fileExists(atPath: $0) ? $0 : nil
                                                          },
                                                          home: NSHomeDirectory()),
                      runningApp: Bundle.main.bundleURL.resolvingSymlinksInPath().path)
        Task { @MainActor in
            // The steps block their thread for minutes while a command runs: a queue of their own, not the task pool.
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, UpdateFailure>, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let built = try Self.perform(job, in: installation) { event in
                            Task { @MainActor in AppUpdater.shared.apply(event) }
                        }
                        continuation.resume(returning: .success(built))
                    } catch {
                        // Reading the log (megabytes after a build) stays off the main thread too.
                        continuation.resume(returning: .failure(UpdateFailure(error, step: installation.step, log: installation.logURL)))
                    }
                }
            }
            self.installation = nil
            switch result {
            case .success(let installed):
                if installation.keptPrevious {
                    UpdateTrialRunner.begin(from: source.commit, to: installed, appPath: job.runningApp)
                }
                finish(update: update, from: source, installed: installed)
            case .failure(let failure):
                phase = .failed(failure)
                AppModel.shared.store.audit(tool: "app_update", args: "\(source.shortCommit) → \(update.shortTarget)",
                                            result: failure.reason == .cancelled ? "cancelled" : "failed: \(failure.summary)")
            }
        }
    }

    /// Installs a release into a downloaded build: download the .zip and its signature, check the signature against the
    /// key in this build, unpack, check the app is Nook at the promised version, put it in place, restart.
    private func installRelease(_ candidate: ReleaseCandidate, over release: ReleaseBuild) {
        guard installation == nil, releaseTask == nil, let publicKey = release.publicKey else { return }
        let installation: Installation
        do {
            installation = try Installation()
        } catch {
            phase = .failed(UpdateFailure(step: .download, reason: .other(error.localizedDescription), errors: [], logPath: nil))
            return
        }
        installation.step = .download
        self.installation = installation
        installStarted = Date()
        compiledFiles = 0
        activity = nil
        phase = .installing(.download)
        let args = "\(release.version) → \(candidate.version)"
        AppModel.shared.store.audit(tool: "app_update", args: args, result: "started")
        let job = ReleaseJob(candidate: candidate, publicKey: publicKey,
                             bundleIdentifier: Bundle.main.bundleIdentifier ?? "nl.imdigital.nook",
                             runningApp: Bundle.main.bundleURL.resolvingSymlinksInPath().path)
        releaseTask = Task { @MainActor in
            var failure: UpdateFailure?
            do {
                try await Self.performRelease(job, in: installation) { step in
                    Task { @MainActor in AppUpdater.shared.apply(.step(step)) }
                }
            } catch {
                let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
                failure = UpdateFailure(cancelled ? InstallError.cancelled : error, step: installation.step, log: installation.logURL)
            }
            self.installation = nil
            releaseTask = nil
            if failure == nil, installation.keptPrevious {
                UpdateTrialRunner.begin(from: release.version.description, to: candidate.version.description, appPath: job.runningApp)
            }
            if let failure {
                phase = .failed(failure)
                AppModel.shared.store.audit(tool: "app_update", args: args,
                                            result: failure.reason == .cancelled ? "cancelled" : "failed: \(failure.summary)")
            } else {
                finishRelease(candidate, from: release)
            }
        }
    }

    private func finishRelease(_ candidate: ReleaseCandidate, from release: ReleaseBuild) {
        let receipt = UpdateReceipt(from: release.version.description, to: candidate.version.description, changes: [],
                                    installedAt: Date())
        if let data = try? JSONEncoder().encode(receipt) { UserDefaults.standard.set(data, forKey: Self.receiptKey) }
        AppModel.shared.store.audit(tool: "app_update", args: "\(release.version) → \(candidate.version)", result: "installed")
        if AppModel.shared.workspace.activeRuns.isEmpty {
            restart()
        } else {
            phase = .readyToRestart
        }
    }

    /// Stops the step that is running. What already happened stays: a fast-forwarded checkout is simply newer than this
    /// build, so the button offers the rest again.
    func cancel() {
        installation?.cancel()
        releaseTask?.cancel()
    }

    /// Closes a failure and goes back to what the last check found.
    func dismissFailure() {
        guard isFailed else { return }
        phase = hasUpdate ? .available : .upToDate
        check()
    }

    func dismissReceipt() {
        receipt = nil
    }

    /// Opens the update panel from the menu bar and Settings: on the tab that is open, every tab has the footer; on
    /// Agents when the panel is closed.
    func showPanel() {
        let viewModel = AppModel.shared.viewModel
        if case .panel = viewModel.state {} else { viewModel.show(.panel(.agents), inNotch: true) }
        panelRequested = true
    }

    private func apply(_ event: Progress) {
        switch event {
        case .step(let step):
            guard case .installing = phase else { return }
            phase = .installing(step)
            activity = nil
        case .activity(let next):
            if case .compiling = next { compiledFiles += 1 }
            activity = next
        }
    }

    private func finish(update: Available, from source: BuildSource, installed target: String) {
        let receipt = UpdateReceipt(from: source.commit, to: target, changes: update.changes, installedAt: Date())
        if let data = try? JSONEncoder().encode(receipt) { UserDefaults.standard.set(data, forKey: Self.receiptKey) }
        AppModel.shared.store.audit(tool: "app_update", args: "\(source.shortCommit) → \(String(target.prefix(7)))",
                                    result: fromXcode ? "checkout updated \(update.count)" : "installed \(update.count)")
        if fromXcode {
            phase = .readyToBuildInXcode
        } else if AppModel.shared.workspace.activeRuns.isEmpty {
            restart()
        } else {
            phase = .readyToRestart
        }
    }

    /// Sessions Nook runs itself stop when Nook restarts (and can be resumed after); terminal sessions are not affected.
    var runningSessions: Int { AppModel.shared.workspace.activeRuns.count }

    /// Set while Nook quits to restart into a new build: you already chose to, so quitting does not ask again.
    private(set) var restarting = false

    /// How long Nook may take to quit for a restart before the panel says it did not, so you can try again or force it.
    /// Well within the minute the relaunch waits for this process (`Relaunch`).
    private static let restartGrace: TimeInterval = 15
    /// How long Nook's own saving at quit may take during a restart before the process ends anyway.
    nonisolated static let quitDeadline: TimeInterval = 30

    /// Quits and opens the app again from where it runs, which now holds the new build.
    func restart() {
        phase = .installing(.restart)
        guard startRelaunch() else { return }
        restarting = true
        NSApp.terminate(nil)
        // Still here: something stopped the quit. Say so instead of spinning on "Restarting Nook" for good.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.restartGrace))
            guard let self, self.phase == .installing(.restart) else { return }
            self.restarting = false
            self.phase = .failed(UpdateFailure(step: .restart, reason: .notRestarted, errors: [], logPath: nil))
        }
    }

    /// Restarts without waiting for a normal quit: stops the sessions Nook runs (as a quit does) and ends the process,
    /// after which the relaunch opens the new build.
    func forceRestart() {
        phase = .installing(.restart)
        guard startRelaunch() else { return }
        restarting = true
        Self.endProcess(after: 10)
        AppModel.shared.workspace.shutdown()
        UpdateTrialRunner.cleanExit()
        fflush(nil)
        _exit(0)
    }

    /// Ends the process from another thread once `seconds` have passed, in case the main thread is stuck while Nook
    /// quits for a restart. `_exit` skips the C++ static destructors, like `AppDelegate` does at a normal quit.
    nonisolated static func endProcess(after seconds: TimeInterval) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            fflush(nil)
            _exit(0)
        }
    }

    /// Starts the shell loop that opens the app again once this process is gone. False (and a failure shown) if it
    /// could not start.
    private func startRelaunch() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // With an update on trial, the relaunch also takes the database snapshot a rollback would put back.
        process.arguments = UpdateTrialRunner.relaunchArguments(pid: ProcessInfo.processInfo.processIdentifier,
                                                                appPath: Bundle.main.bundlePath)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            phase = .failed(UpdateFailure(step: .restart, reason: .other(error.localizedDescription), errors: [], logPath: nil))
            return false
        }
    }

    /// Opens the project in Xcode and runs it there: Xcode builds the updated checkout, stops this process and starts the
    /// new one. Without permission to control Xcode the project still opens, and ⌘R does the rest.
    func buildInXcode() {
        guard let source, phase == .readyToBuildInXcode else { return }
        let project = source.projectPath
        // The Xcode that built this app (…/Xcode.app/Contents/Developer), else the one macOS knows.
        let xcode = source.developerDirectory
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent() }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
        Task.detached(priority: .userInitiated) {
            let target = xcode.map { "application \(AppleScriptText.literal($0.path))" } ?? "application id \"com.apple.dt.Xcode\""
            let script = """
            tell \(target)
                activate
                set doc to open (POSIX file \(AppleScriptText.literal(project)))
                repeat 120 times
                    if loaded of doc is true then exit repeat
                    delay 0.5
                end repeat
                run doc
            end tell
            """
            guard SystemControl.appleScriptResult(script, timeout: 90).errorNumber != nil else { return }
            await MainActor.run {
                let file = URL(fileURLWithPath: project)
                if let xcode {
                    NSWorkspace.shared.open([file], withApplicationAt: xcode, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(file)
                }
            }
        }
    }

    /// `build`: this build's commit, or its release version.
    /// The new build crashed before it proved healthy, and this (previous) build and its database were put back
    /// (`UpdateTrialRunner`): shown as a failed update, with what happened.
    func reportRollback(_ trial: UpdateTrial) {
        let failed = BuildSource.isCommit(trial.to) ? String(trial.to.prefix(7)) : trial.to
        let current = BuildSource.isCommit(trial.from) ? String(trial.from.prefix(7)) : trial.from
        phase = .failed(UpdateFailure(step: .restart, reason: .rolledBack(failed), errors: [], logPath: nil))
        AppModel.shared.store.audit(tool: "app_update", args: "\(failed) → \(current)", result: "rolled back")
    }

    private func loadReceipt(for build: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.receiptKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.receiptKey)
        guard let saved = try? JSONDecoder().decode(UpdateReceipt.self, from: data), saved.to == build,
              Date().timeIntervalSince(saved.installedAt) < 24 * 3600 else { return }
        receipt = saved
    }

    // MARK: The install, off the main thread

    enum Progress: Sendable {
        case step(UpdateStep)
        case activity(BuildActivity)
    }

    struct Job: Sendable {
        let source: BuildSource
        let update: Available
        let git: GitService
        let allowStash: Bool
        /// Stop once the project is generated: Xcode builds it.
        let buildInXcode: Bool
        let environment: [String: String]
        let runningApp: String
    }

    struct ReleaseJob: Sendable {
        let candidate: ReleaseCandidate
        let publicKey: Data
        let bundleIdentifier: String
        let runningApp: String
    }

    /// The release install's steps. Downloads are awaited (cancelling the task stops them); unpacking and copying block
    /// a thread of their own, like the steps of a checkout's install.
    nonisolated static func performRelease(_ job: ReleaseJob, in installation: Installation,
                                           report: @escaping @Sendable (UpdateStep) -> Void) async throws {
        func enter(_ step: UpdateStep) {
            installation.step = step
            report(step)
        }
        let fileManager = FileManager.default
        let folder = fileManager.temporaryDirectory.appendingPathComponent("nook-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folder) }

        enter(.download)
        installation.note("\n== download \(job.candidate.signature.url.absoluteString)\n")
        let signatureFile = try await download(job.candidate.signature.url, to: folder.appendingPathComponent("archive.sig"))
        installation.note("== download \(job.candidate.archive.url.absoluteString)\n")
        let archive = try await download(job.candidate.archive.url, to: folder.appendingPathComponent("archive.zip"))
        try installation.checkCancelled()

        enter(.verify)
        try await onOwnThread {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard let signature = try? Data(contentsOf: signatureFile),
                  UpdateSignature.verify(archive: data, signatureFile: signature, publicKey: job.publicKey, using: Ed25519Verifier())
            else { throw InstallError.badSignature }
            installation.note("signature ok (\(data.count) bytes)\n")
        }
        let unpacked = folder.appendingPathComponent("unpacked", isDirectory: true)
        let app: URL = try await onOwnThread {
            try installation.run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path], in: folder.path,
                                 environment: ProcessInfo.processInfo.environment, timeout: 600)
            guard let bundle = try fileManager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else { throw InstallError.badBundle("no app") }
            let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
            switch ReleaseBundleCheck.problem(info: info, bundleIdentifier: job.bundleIdentifier, expected: job.candidate.version) {
            case .notNook?: throw InstallError.badBundle(info["CFBundleIdentifier"] as? String ?? "?")
            case .wrongVersion(let version)?: throw InstallError.badBundle(version ?? "?")
            case nil: break
            }
            // The code inside is intact (an ad-hoc or self-signed build verifies too; it is the .zip's signature that
            // says who made it).
            try installation.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path], in: folder.path,
                                 environment: ProcessInfo.processInfo.environment, timeout: 300)
            return bundle
        }
        try installation.checkCancelled()

        enter(.install)
        installation.keptPrevious = try await onOwnThread {
            try replace(job.runningApp, with: app.path, keepPreviousAt: UpdateTrialRunner.keptAppURL)
        }
    }

    /// Downloads a release file to `destination`.
    nonisolated private static func download(_ url: URL, to destination: URL) async throws -> URL {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw InstallError.download("HTTP \(status)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }

    /// Blocking work (reading a large file, a command) on a queue of its own instead of the task pool.
    nonisolated private static func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Runs every step and returns the commit that was built.
    nonisolated static func perform(_ job: Job, in installation: Installation,
                                    report: @escaping @Sendable (Progress) -> Void) throws -> String {
        let git = job.git
        let repository = job.update.repository
        let upstream = "\(job.update.remote)/\(job.update.branch)"
        func runGit(_ arguments: [String], timeout: TimeInterval = 120) throws {
            try installation.run(git.executable, ["-C", repository] + arguments, in: repository, environment: job.environment,
                                 timeout: timeout)
        }

        func enter(_ step: UpdateStep) {
            installation.step = step
            report(.step(step))
        }

        enter(.fetch)
        try runGit(["fetch", "--no-tags", job.update.remote, job.update.branch], timeout: 300)
        let target = try git.run(["rev-parse", "--verify", "\(upstream)^{commit}"], in: repository).trimmed
        // Read again: the checkout may have changed since the check.
        let checkout = try readCheckout(repository, remote: job.update.remote, branch: job.update.branch, target: target, git: git)
        switch UpdatePreflight.check(checkout) {
        case .blocked(let blocker): throw InstallError.blocked(blocker)
        case .needsStash(let files): if !job.allowStash { throw InstallError.needsStash(files) }
        case .ready: break
        }

        enter(.merge)
        if !checkout.atTarget {
            var stash: String?
            if !checkout.changedFiles.isEmpty {
                let name = "nook-update-" + ISO8601DateFormatter().string(from: Date())
                try runGit(["stash", "push", "--include-untracked", "-m", name])
                stash = name
            }
            do {
                try runGit(["merge", "--ff-only", upstream])
            } catch {
                if stash != nil { try? runGit(["stash", "pop"]) }
                throw error
            }
            if let stash {
                do { try runGit(["stash", "pop"]) } catch { throw InstallError.stashConflict(stash) }
            }
        }

        enter(.generate)
        let project = job.source.projectDirectory
        guard let xcodegen = locate("xcodegen", environment: job.environment) else { throw InstallError.missingTool("xcodegen") }
        try installation.run(xcodegen, ["generate"], in: project, environment: job.environment, timeout: 600)
        if job.buildInXcode { return target }

        enter(.build)
        let xcodebuild = "/usr/bin/xcodebuild"
        let common = ["-project", job.source.projectPath, "-scheme", "Nook",
                      "-configuration", job.source.configuration, "-destination", "platform=macOS"]
        try installation.run(xcodebuild, common + ["-skipMacroValidation", "-skipPackagePluginValidation", "build"], in: project,
                             environment: job.environment, timeout: 90 * 60) { line in
            if let activity = BuildActivity.parse(line) { report(.activity(activity)) }
        }
        let settings = try ProcessRunner.run(xcodebuild, common + ["-showBuildSettings", "-json"], in: project,
                                             environment: job.environment, timeout: 300)
        guard settings.status == 0, let product = BuildProduct.path(fromBuildSettings: Data(settings.stdout.utf8)),
              FileManager.default.fileExists(atPath: product) else { throw InstallError.noProduct }

        enter(.install)
        try installation.checkCancelled()
        installation.keptPrevious = try replace(job.runningApp, with: product, keepPreviousAt: UpdateTrialRunner.keptAppURL)
        return target
    }

    /// Puts the new build where this app runs. Built in place (Xcode's DerivedData, the usual case) there is nothing to
    /// do: the linker and codesign write new files, so the running app keeps its own. A copy elsewhere (/Applications)
    /// is swapped: copy next to it, move the old one aside, move the new one in, and put the old one back if that fails.
    /// The old one is then kept at `keep` for a rollback (`UpdateTrial`) when it can be moved there; true when it was.
    @discardableResult
    nonisolated static func replace(_ running: String, with built: String, keepPreviousAt keep: URL? = nil) throws -> Bool {
        let fileManager = FileManager.default
        let runningURL = URL(fileURLWithPath: running).standardizedFileURL.resolvingSymlinksInPath()
        let builtURL = URL(fileURLWithPath: built).standardizedFileURL.resolvingSymlinksInPath()
        guard runningURL.path != builtURL.path else { return false }
        let folder = runningURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: folder.path) else { throw InstallError.notWritable(folder.path) }
        let staging = folder.appendingPathComponent(".\(runningURL.lastPathComponent).update")
        let previous = folder.appendingPathComponent(".\(runningURL.lastPathComponent).previous")
        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: previous)
        let copy = try ProcessRunner.run("/usr/bin/ditto", [builtURL.path, staging.path], timeout: 600)
        guard copy.status == 0 else {
            try? fileManager.removeItem(at: staging)
            throw InstallError.copyFailed(copy.stderr.trimmed)
        }
        do {
            try fileManager.moveItem(at: runningURL, to: previous)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw InstallError.copyFailed(error.localizedDescription)
        }
        do {
            try fileManager.moveItem(at: staging, to: runningURL)
        } catch {
            try? fileManager.moveItem(at: previous, to: runningURL)
            throw InstallError.copyFailed(error.localizedDescription)
        }
        if let keep {
            try? fileManager.removeItem(at: keep)
            try? fileManager.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fileManager.moveItem(at: previous, to: keep)) != nil { return true }
        }
        try? fileManager.removeItem(at: previous)
        return false
    }

    /// A tool in the usual places, or wherever your login shell finds it.
    nonisolated static func locate(_ tool: String, environment: [String: String]) -> String? {
        let fileManager = FileManager.default
        for folder in (environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(folder)/\(tool)"
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        let shell = environment["SHELL"].flatMap { fileManager.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        guard let output = try? ProcessRunner.run(shell, ["-lc", "command -v \(tool)"], environment: environment, timeout: 15),
              output.status == 0 else { return nil }
        let path = output.stdout.split(whereSeparator: \.isNewline).last.map(String.init)?.trimmed ?? ""
        return fileManager.isExecutableFile(atPath: path) ? path : nil
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Why an install stopped.
enum InstallError: Error, Equatable {
    case blocked(UpdateBlocker)
    case needsStash(Int)
    case stashConflict(String)
    case missingTool(String)
    case failed(step: String, status: Int32)
    case timedOut(String)
    case noProduct
    case notWritable(String)
    case copyFailed(String)
    case cancelled
    /// A release download failed.
    case download(String)
    /// The release's .zip does not match its signature.
    case badSignature
    /// The unpacked release is not Nook, or not the version the release promised.
    case badBundle(String)
}

/// A failed install, for the footer and its panel.
struct UpdateFailure: Error, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case blocked(UpdateBlocker)
        case needsStash(Int)
        case stashConflict(String)
        case missingTool(String)
        case command(Int32)
        case timedOut
        case noProduct
        case notWritable(String)
        case copyFailed(String)
        case cancelled
        case download(String)
        case badSignature
        case badBundle(String)
        /// The new build crashed before it proved healthy; this one and its database were put back.
        case rolledBack(String)
        /// The new build is in place, but Nook did not quit to start it (something stopped or held up the quit).
        case notRestarted
        case other(String)
    }

    let step: UpdateStep
    let reason: Reason
    /// The compiler's errors, when the build failed.
    let errors: [String]
    let logPath: String?

    init(step: UpdateStep, reason: Reason, errors: [String], logPath: String?) {
        self.step = step
        self.reason = reason
        self.errors = errors
        self.logPath = logPath
    }

    init(_ error: Error, step: UpdateStep, log: URL) {
        let reason: Reason
        switch error as? InstallError {
        case .blocked(let blocker): reason = .blocked(blocker)
        case .needsStash(let files): reason = .needsStash(files)
        case .stashConflict(let name): reason = .stashConflict(name)
        case .missingTool(let tool): reason = .missingTool(tool)
        case .failed(_, let status): reason = .command(status)
        case .timedOut: reason = .timedOut
        case .noProduct: reason = .noProduct
        case .notWritable(let folder): reason = .notWritable(folder)
        case .copyFailed(let message): reason = .copyFailed(message)
        case .cancelled: reason = .cancelled
        case .download(let message): reason = .download(message)
        case .badSignature: reason = .badSignature
        case .badBundle(let found): reason = .badBundle(found)
        case nil: reason = .other(error.localizedDescription)
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        self.init(step: step, reason: reason, errors: step == .build ? BuildActivity.errors(in: text) : [],
                  logPath: FileManager.default.fileExists(atPath: log.path) ? log.path : nil)
    }

    /// One line for the action log.
    var summary: String {
        if let first = errors.first { return first }
        switch reason {
        case .other(let message), .copyFailed(let message), .download(let message): return message
        default: return "\(step)"
        }
    }
}

/// One install: its log file and the process running now, so it can be cancelled. Used from one background task.
final class Installation: @unchecked Sendable {
    let logURL: URL
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var current = UpdateStep.fetch
    private var kept = false

    /// The install kept the previous app for a rollback.
    var keptPrevious: Bool {
        get { lock.lock(); defer { lock.unlock() }; return kept }
        set { lock.lock(); kept = newValue; lock.unlock() }
    }

    /// The step running now, for the failure message.
    var step: UpdateStep {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }

    init() throws {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        logURL = folder.appendingPathComponent("Update-\(formatter.string(from: Date())).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        running?.terminate()
    }

    /// A line in the log for a step that runs no command (a download, the signature check).
    func note(_ text: String) {
        append(text)
    }

    func checkCancelled() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw InstallError.cancelled }
    }

    /// Runs one command with its output going straight into the log (a file never fills up the way a pipe can, and a
    /// helper that outlives xcodebuild cannot keep it open). `onLine` gets every new line while it runs.
    func run(_ executable: String, _ arguments: [String], in directory: String, environment: [String: String],
             timeout: TimeInterval, onLine: ((String) -> Void)? = nil) throws {
        try checkCancelled()
        let name = URL(fileURLWithPath: executable).lastPathComponent
        append("\n== \(name) \(arguments.joined(separator: " "))\n")
        let output = try FileHandle(forWritingTo: logURL)
        defer { try? output.close() }
        output.seekToEndOfFile()
        let reader = try FileHandle(forReadingFrom: logURL)
        defer { try? reader.close() }
        reader.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        lock.lock()
        self.process = process
        lock.unlock()
        defer {
            lock.lock()
            self.process = nil
            lock.unlock()
        }
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        var partial = ""
        func readLines() {
            guard let onLine else { return }
            let data = reader.readDataToEndOfFile()
            guard !data.isEmpty else { return }
            partial += String(decoding: data, as: UTF8.self)
            var lines = partial.components(separatedBy: "\n")
            partial = lines.removeLast()
            lines.forEach(onLine)
        }
        var timedOut = false
        while process.isRunning {
            Thread.sleep(forTimeInterval: 0.4)
            readLines()
            if Date() > deadline {
                timedOut = true
                process.terminate()
                break
            }
        }
        process.waitUntilExit()
        readLines()
        try checkCancelled()
        if timedOut { throw InstallError.timedOut(name) }
        guard process.terminationStatus == 0 else { throw InstallError.failed(step: name, status: process.terminationStatus) }
    }

    private func append(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }
}
