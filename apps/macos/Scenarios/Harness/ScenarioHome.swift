import AppKit
import ObjectiveC

/// The scenario home: the only place a scenario writes. scripts/scenarios.sh makes it fresh for every run and starts the
/// test process with `CFFIXED_USER_HOME` pointing at it, so every path the app derives from the home folder
/// (Application Support, ~/.nook, ~/.claude) lands here; `prepare()` checks that before any app type is touched, and
/// moves the app's preferences, NookPaths and the agents' environment there too.
enum ScenarioHome {
    struct Paths {
        let home: URL
        let output: URL
        let shim: URL
        let recordings: URL
        let replayState: URL
        let workspaces: URL
    }

    private(set) static var paths: Paths?
    private static var failure: String?

    /// Sets the process up once; throws `couldNotRun` when the run was not started the way it must be.
    static func prepare() throws -> Paths {
        if let paths { return paths }
        if let failure { throw ScenarioFailure.couldNotRun(failure) }
        do {
            let made = try make()
            paths = made
            return made
        } catch let error as ScenarioFailure {
            failure = error.message
            throw error
        }
    }

    private static func make() throws -> Paths {
        let environment = ProcessInfo.processInfo.environment
        guard let homePath = environment["NOOK_SCENARIO_HOME"], let outPath = environment["NOOK_SCENARIO_OUT"] else {
            throw ScenarioFailure.couldNotRun("NOOK_SCENARIO_HOME and NOOK_SCENARIO_OUT are not set: run scenarios with scripts/scenarios.sh")
        }
        let home = URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        // The test process must already see the scenario home as its home folder (CFFIXED_USER_HOME): paths the app
        // computes from it cannot be moved afterwards.
        let seen = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        guard seen.resolvingSymlinksInPath().path == home.resolvingSymlinksInPath().path,
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath().path
                == home.resolvingSymlinksInPath().path else {
            throw ScenarioFailure.couldNotRun("the test process's home is \(seen.path), not the scenario home \(home.path) (CFFIXED_USER_HOME)")
        }
        guard home.path.contains("/.scratch/scenarios/") || home.path.contains("/.build/prove/") else {
            throw ScenarioFailure.couldNotRun("the scenario home \(home.path) is not inside a checkout's .scratch/scenarios")
        }
        let fileManager = FileManager.default
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support/Nook", isDirectory: true)
        let replayState = home.appendingPathComponent("replay", isDirectory: true)
        let workspaces = home.appendingPathComponent("workspaces", isDirectory: true)
        for folder in [bin, preferences, support, replayState, workspaces] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let bundle = Bundle(for: ScenarioBundleMarker.self)
        guard let shimSource = bundle.url(forResource: "claude", withExtension: nil),
              let recordings = bundle.url(forResource: "Recordings", withExtension: nil) else {
            throw ScenarioFailure.couldNotRun("the replay agent or the recordings are missing from the NookScenarios bundle")
        }
        let shim = bin.appendingPathComponent("claude")
        try? fileManager.removeItem(at: shim)
        do {
            try fileManager.copyItem(at: shimSource, to: shim)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
        } catch {
            throw ScenarioFailure.couldNotRun("could not install the replay agent: \(error.localizedDescription)")
        }

        // The app's preferences: a file in the scenario home instead of the test tool's domain in ~/Library/Preferences.
        // Not inside the home's Library/Preferences: cfprefsd takes a file there for a domain of the real user's.
        let defaultsFile = home.appendingPathComponent("preferences.plist").path
        guard let defaults = UserDefaults(suiteName: defaultsFile) else {
            throw ScenarioFailure.couldNotRun("could not open the scenario's preferences at \(defaultsFile)")
        }
        ScenarioDefaults.instance = defaults
        ScenarioDefaults.install()
        // English, no onboarding, the main window on the Agents tab.
        defaults.set("en", forKey: "appLanguage")
        defaults.set(true, forKey: "onboardingDone")
        defaults.set("agents", forKey: "window.lastTab")
        defaults.synchronize()
        guard FileManager.default.fileExists(atPath: defaultsFile) else {
            throw ScenarioFailure.couldNotRun("the scenario's preferences did not land in \(defaultsFile)")
        }

        // What the agents Nook starts see: the scenario home, the replay agent first on PATH, and none of the user's keys.
        setenv("HOME", home.path, 1)
        setenv("PATH", bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin", 1)
        setenv("NOOK_SCENARIO_SHIM", shim.path, 1)
        setenv("NOOK_REPLAY_RECORDINGS", recordings.path, 1)
        setenv("NOOK_REPLAY_STATE", replayState.path, 1)
        if getenv("NOOK_REPLAY_SPEED") == nil { setenv("NOOK_REPLAY_SPEED", "1", 1) }
        for key in ProcessInfo.processInfo.environment.keys
        where key.hasPrefix("ANTHROPIC_") || key.hasPrefix("CLAUDE_") || key.hasPrefix("OPENAI_") || key.hasPrefix("GEMINI_")
            || key.hasPrefix("GOOGLE_") || key == "CODEX_HOME" || key.hasPrefix("NOOK_RUN") || key == "SSH_AUTH_SOCK" {
            unsetenv(key)
        }

        NookPaths.supportDirectory = support
        ScenarioRuntimeGuards.install(mainBundle: bundle)

        // The replay agent answers, and says it is the replay agent.
        let probe = Process()
        probe.executableURL = shim
        probe.arguments = ["--version"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        do {
            try runToEnd(probe)
        } catch {
            throw ScenarioFailure.couldNotRun("the replay agent does not start: \(error.localizedDescription)")
        }
        let version = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard version.contains("Claude Code replay") else {
            throw ScenarioFailure.couldNotRun("\(shim.path) is not the replay agent (it answered \(version.prefix(80)))")
        }
        return Paths(home: home, output: URL(fileURLWithPath: outPath, isDirectory: true), shim: shim, recordings: recordings,
                     replayState: replayState, workspaces: workspaces)
    }

    /// Runs a short program to its end without turning the run loop: `waitUntilExit` would, and on the main thread
    /// that runs other main-actor work in the middle of the scenario's own.
    static func runToEnd(_ process: Process) throws {
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + 60) == .timedOut {
            process.terminate()
            throw ScenarioFailure.couldNotRun("\(process.executableURL?.lastPathComponent ?? "a program") did not end within 60 s")
        }
    }

    /// Refusals the C guard wrote (a real agent that was about to start).
    static func drainSpawnRefusals() -> [String] {
        guard let home = paths?.home else { return [] }
        let log = home.appendingPathComponent("guard-violations.log")
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return [] }
        try? FileManager.default.removeItem(at: log)
        return text.split(separator: "\n").map(String.init)
    }
}

/// `UserDefaults.standard` (and so every `@AppStorage`) is the scenario's own preferences file.
enum ScenarioDefaults {
    static var instance: UserDefaults?
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        guard let meta = object_getClass(UserDefaults.self),
              let original = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)),
              let replacement = class_getClassMethod(UserDefaults.self, #selector(UserDefaults.scenario_standard)) else { return }
        if class_addMethod(meta, #selector(getter: UserDefaults.standard), method_getImplementation(replacement),
                           method_getTypeEncoding(replacement)) {
            class_replaceMethod(meta, #selector(UserDefaults.scenario_standard), method_getImplementation(original),
                                method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, replacement)
        }
    }
}

extension UserDefaults {
    @objc class func scenario_standard() -> UserDefaults {
        ScenarioDefaults.instance ?? scenario_standard()
    }
}
