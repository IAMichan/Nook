import AppKit
import SwiftUI

/// `nook` in a scenario: state made through the app's own code paths (the Nook equivalent of t3code's `t3` fixture).
/// Sessions start through `WorkspaceManager.start`, the path `session_start` and `nook start` take, and run the replay
/// agent; `open` hosts the main window's real view offscreen.
@MainActor
final class NookFixture {
    struct Project {
        let name: String
        let path: String
    }

    struct Session {
        let id: UUID
        let title: String
    }

    let scenario: Scenario
    let paths: ScenarioHome.Paths
    let screen: Screen
    /// A guard refusing to start a real agent fails the scenario (it could not run); a scenario about that refusal
    /// turns it off.
    var agentRefusalsFail = true
    private var sessions: [UUID] = []
    private var window: NSWindow?

    init(scenario: Scenario, paths: ScenarioHome.Paths, screen: Screen) {
        self.scenario = scenario
        self.paths = paths
        self.screen = screen
    }

    /// Nook's app model, made the first time a scenario needs it (never started: no notch, no hooks, no connectors),
    /// with the replay agent as every agent's program.
    var app: AppModel {
        let app = AppModel.shared
        let shim = paths.shim.path
        app.workspace.executable = { _ in shim }
        app.workspace.accountExecutable = { _ in nil }
        app.workspace.accountEnvironment = { _ in [:] }
        return app
    }

    // MARK: Projects

    /// Creates a git repository named `name` holding `files` (text, or `Data` for binary files) in the scenario home.
    @discardableResult
    func project(_ name: String, files: [String: Any] = [:]) throws -> Project {
        try scenario.step("nook.project", name) {
            let parent = paths.workspaces.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            let folder = parent.appendingPathComponent(name, isDirectory: true)
            let fileManager = FileManager.default
            var all: [String: Any] = ["README.md": "# \(name)\n"]
            all.merge(files) { _, new in new }
            for (relative, content) in all {
                let url = folder.appendingPathComponent(relative)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let data = content as? Data {
                    try data.write(to: url)
                } else {
                    try Data("\(content)".utf8).write(to: url)
                }
            }
            let author = ["-c", "user.name=Scenario", "-c", "user.email=scenario@example.invalid", "-c", "commit.gpgsign=false"]
            try git(["init", "--quiet", "--initial-branch=main"], in: folder)
            try git(["add", "--all"], in: folder)
            try git(author + ["commit", "--quiet", "--message", "Initial commit"], in: folder)
            return Project(name: name, path: folder.resolvingSymlinksInPath().path)
        }
    }

    private func git(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        // The scenario home, without the user's git configuration.
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = paths.home.path
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        try ScenarioHome.runToEnd(process)
        guard process.terminationStatus == 0 else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ScenarioFailure.couldNotRun("git \(arguments.last ?? "") failed: \(message)")
        }
    }

    // MARK: Sessions

    /// Starts a Claude Code session in `project` with the replay agent playing `recording`, and plays one turn per
    /// message. With `wait`, it returns when the last turn finished; otherwise as soon as the first turn runs.
    @discardableResult
    func session(project: Project, title: String, messages: [String], recording: String = "showcase",
                 wait: Bool = true) throws -> Session {
        try scenario.step("nook.session", "\(title) (\(recording), \(messages.count) message(s))") {
            guard let first = messages.first else { throw ScenarioFailure.couldNotRun("a session needs a first message") }
            let workspace = app.workspace
            var config = NewRunConfig()
            config.title = title
            config.task = first
            config.provider = .claude
            config.profileID = "claude"
            config.model = recording
            config.permission = RunProvider.claude.capabilities.policies.contains(.ask) ? .ask : .acceptEdits
            config.isolation = .folder
            config.projectPath = project.path
            config.startedBy = "Started by a scenario"
            let id: UUID
            do {
                id = try ScenarioClock.run { try await workspace.start(config, allowSharedFolder: true) }
            } catch {
                throw ScenarioFailure.couldNotRun("the session did not start: \(error.localizedDescription)")
            }
            sessions.append(id)
            let session = Session(id: id, title: title)
            try verifyReplayAgent(session)
            if wait || messages.count > 1 { try waitForTurn(session) }
            for message in messages.dropFirst() {
                try sendNow(session, message)
                if wait { try waitForTurn(session) }
            }
            return session
        }
    }

    /// Sends a message to a session as the composer does, and with `wait` returns when its turn finished.
    func send(_ session: Session, _ text: String, wait: Bool = true) throws {
        try scenario.step("nook.send", text) {
            try sendNow(session, text)
            if wait { try waitForTurn(session) }
        }
    }

    private func sendNow(_ session: Session, _ text: String) throws {
        guard app.workspace.send(session.id, text: text) else {
            throw ScenarioFailure.couldNotRun("the session did not take the message \"\(text)\"")
        }
        // The turn starts on the next run loop turns.
        ScenarioClock.spin(nanoseconds: 200_000_000)
    }

    /// Waits until the session's turn ended; a failed turn means the scenario could not run.
    func waitForTurn(_ session: Session, timeout: TimeInterval = 60) throws {
        let end = Date().addingTimeInterval(timeout)
        while true {
            screen.refresh()
            guard let run = app.workspace.run(session.id) else { throw ScenarioFailure.couldNotRun("the session is gone") }
            if !run.status.isActive, run.status != .preparing {
                if run.status == .failed {
                    throw ScenarioFailure.couldNotRun("the turn failed: \(run.statusDetail ?? "no detail")")
                }
                return
            }
            if Date() > end { throw ScenarioFailure.couldNotRun("the turn did not finish within \(Int(timeout)) s") }
            ScenarioClock.spin(nanoseconds: 100_000_000)
        }
    }

    /// Fails loudly unless the session's agent process is the replay agent, and the replay agent saw this project.
    private func verifyReplayAgent(_ session: Session) throws {
        let end = Date().addingTimeInterval(20)
        let workspace = app.workspace
        while Date() < end {
            if let process = workspace.processes[session.id] {
                guard process.spec.executable == paths.shim.path else {
                    throw ScenarioFailure.couldNotRun("the session runs \(process.spec.executable), not the replay agent")
                }
                break
            }
            if let run = workspace.run(session.id), !run.status.isActive, run.status != .preparing { break }
            ScenarioClock.spin(nanoseconds: 50_000_000)
        }
        let folder = workspace.run(session.id)?.workingDirectory ?? ""
        let log = paths.replayState.appendingPathComponent("launches.log")
        while Date() < end {
            if let text = try? String(contentsOf: log, encoding: .utf8), text.contains("cwd=" + folder) { return }
            ScenarioClock.spin(nanoseconds: 50_000_000)
        }
        throw ScenarioFailure.couldNotRun("the replay agent never started in \(folder)")
    }

    // MARK: Window

    /// Hosts the main window's real content (`WorkspaceView`: the panel with the Agents tab and its session) in a
    /// window that is never on screen, showing `session`.
    func open(_ session: Session, size: CGSize = CGSize(width: 1240, height: 800)) throws {
        try scenario.step("nook.open", session.title) {
            let app = self.app
            app.workspace.selectedRunID = session.id
            app.viewModel.windowSheet = nil
            app.viewModel.windowTab = .agents
            app.viewModel.selectedAgentID = "run:" + session.id.uuidString
            if window == nil {
                let presence = WindowPresence()
                let root = WindowContent(presence: presence, background: NookTheme.canvas, minSize: CGSize(width: 900, height: 580)) {
                    WorkspaceView()
                }
                    .nookAttention()
                    .environmentObject(app)
                    .environmentObject(app.workspace)
                    .environmentObject(app.workspace.settings)
                let host = WorkspaceHostingView(rootView: root)
                host.sizingOptions = []
                // Far outside every screen and never ordered in: nothing shows, nothing takes focus.
                let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                NookWindowLook.adopt(window)
                window.titlebarAppearsTransparent = true
                window.titleVisibility = .hidden
                window.toolbar = NSToolbar(identifier: "NookScenario")
                window.toolbarStyle = .unified
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
                // SwiftUI builds its accessibility elements only once something asks for them as an assistive app does:
                // this process asks for them itself (these settings hold for this process only).
                Self.setFlag(host, "set_accessibilityAllowsAutomationElements:", true)
                self.window = window
                screen.window = window
            }
            screen.settle(1.0)
        }
    }

    /// Calls a one-`BOOL` setter by name, when the object has it.
    private static func setFlag(_ object: NSObject?, _ name: String, _ value: Bool) {
        let selector = NSSelectorFromString(name)
        guard let object, object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector) else {
            NSLog("NookScenarios: %@ is not available", name)
            return
        }
        typealias Setter = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(object, selector, value)
    }

    // MARK: Teardown

    func tearDown() {
        let workspace = AppModel.shared.workspace
        for id in sessions {
            if workspace.run(id)?.status.isActive == true { workspace.stop(id) }
        }
        ScenarioClock.spin(nanoseconds: 300_000_000)
        for id in sessions { workspace.delete(id, cleanUpWorktree: false) }
        sessions = []
        if let window {
            window.contentView = nil
            window.close()
        }
        window = nil
        screen.window = nil
    }
}
