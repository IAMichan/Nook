import SwiftUI
import AppKit
import SwiftTerm

/// The agent that started a terminal through the workspace bridge (`terminal_run`).
struct TerminalOwner: Equatable {
    /// Display name: "Claude Code".
    let agent: String
    /// `BridgeCaller.key`: only this caller may stop the terminal.
    let key: String
}

/// One terminal in Nook's window: a real shell in a pseudo-terminal, started in a folder, optionally with a command.
/// Sessions stay alive while you switch tabs; closing one ends its shell.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    /// Short id agents use to refer to it: "t3".
    let shortID: String
    /// Set when an agent started it; nil for terminals you opened.
    let owner: TerminalOwner?
    /// The command it was started with, if any.
    let command: String?
    @Published var title: String
    @Published private(set) var directory: String
    /// The folder it was opened in, so it stays with that session even after a `cd` elsewhere.
    let origin: String
    @Published private(set) var exitCode: Int32?
    @Published private(set) var running = true
    let created = Date()
    let view: NookTerminalView

    init(title: String, directory: String, command: String?, shortID: String = "", owner: TerminalOwner? = nil) {
        self.title = title
        self.directory = directory
        self.shortID = shortID
        self.owner = owner
        self.command = command
        origin = directory
        view = NookTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
        view.linkBase = { [weak self] in self?.directory }
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["NOOK_TERMINAL"] = "1"
        // Start in the folder; run the command if there is one, then keep an interactive shell open so its output stays.
        var script = "cd \(TerminalLauncher.shellQuote(directory)) 2>/dev/null; "
        if let command, !command.isEmpty { script += command + "; " }
        script += "exec \(TerminalLauncher.shellQuote(shell)) -l"
        view.startProcess(executable: shell, args: ["-l", "-c", script], environment: environment.map { "\($0.key)=\($0.value)" })
    }

    func close() {
        if running { view.terminate() }
        running = false
    }

    /// The last `lines` lines on screen and in the scrollback, for an agent to read.
    func output(lines: Int) -> String {
        let data = view.getTerminal().getBufferAsData()
        return TerminalText.tail(String(decoding: data, as: UTF8.self), lines: lines)
    }

    /// Ctrl-C to whatever runs in the shell; the shell itself stays open so the output remains readable.
    func interrupt() {
        guard running else { return }
        view.send(txt: "\u{03}")
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = TerminalTitle.display(title) } }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path = URL(string: directory)?.path ?? directory
        Task { @MainActor in self.directory = path }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.running = false
            self.exitCode = exitCode
        }
    }
}

/// The terminal view, with ⌘-click on a link handled the Nook way: an address on this Mac
/// (`http://localhost:5173`) opens in Nook's browser, any other web address in your browser, and a path the terminal shows
/// (`./src/app.swift:12:3`, `~/notes.md`, `/abs/file.ts`) in your editor at that line. Other links (`ssh:`, `magnet:`…)
/// are left alone.
final class NookTerminalView: LocalProcessTerminalView {
    /// The folder a relative path is read from: where the shell is now.
    var linkBase: @MainActor () -> String? = { nil }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let base = MainActor.assumeIsolated { linkBase() }
        let text = link.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if TerminalLinks.isURL(text), let url = URL(string: text) {
                if TerminalLinks.isLocal(url) {
                    BrowserStore.shared.open(url)
                    BrowserPopup.shared.show()
                } else {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            // The terminal's own match can carry sentence punctuation; read it the way the link parser does.
            let path = TerminalLinks.extract(text).first { $0.kind == .path }?.text ?? text
            guard let target = FileLink.parse(path), let resolved = FileLink.resolve(target, base: base) else { return }
            AppModel.shared.workspace.openFile(resolved)
        }
    }
}

/// All open terminals. Shared by the workspace, agent sessions ("Open terminal here") and account sign-in.
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selected: UUID?
    private var opened = 0

    @discardableResult
    func open(in directory: String, command: String? = nil, title: String? = nil, owner: TerminalOwner? = nil) -> TerminalSession {
        let name = title ?? URL(fileURLWithPath: directory).lastPathComponent
        opened += 1
        let session = TerminalSession(title: name.isEmpty ? "Terminal" : name, directory: directory, command: command,
                                      shortID: "t\(opened)", owner: owner)
        sessions.append(session)
        selected = session.id
        return session
    }

    /// The terminals opened in `folder` or below it: the ones that belong to the session working there.
    func sessions(in folder: String) -> [TerminalSession] {
        let root = Self.normalized(folder)
        return sessions.filter {
            let origin = Self.normalized($0.origin)
            return origin == root || origin.hasPrefix(root + "/")
        }
    }

    /// A terminal by its short id ("t3") or its full id.
    func session(_ reference: String) -> TerminalSession? {
        let key = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sessions.first { $0.shortID == key || $0.id.uuidString.lowercased() == key }
    }

    private static func normalized(_ path: String) -> String {
        let standard = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
        return standard.count > 1 && standard.hasSuffix("/") ? String(standard.dropLast()) : standard
    }

    func close(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.close()
        sessions.removeAll { $0.id == id }
        if selected == id { selected = sessions.last?.id }
    }
}

/// A container that never asks for a size of its own: the terminal fills whatever SwiftUI gives it. A terminal view that
/// reports an intrinsic size makes the window re-run its layout again and again.
private final class TerminalContainer: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

extension TerminalStore {
    /// The one way Nook's brain touches a shell: it proposes a command, the user approves the whole command in the plan,
    /// and it runs in a visible terminal in the workspace, so output and errors can be read there. There is no read-only
    /// variant and no hidden execution.
    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "run_command",
                description: "Runs a shell command in a visible terminal of Nook's workspace, in an optional folder. Use it only when the user asks for something that needs a command line; the user approves the exact command first and sees its output in the terminal.",
                schema: [
                    "type": "object",
                    "properties": [
                        "command": ["type": "string", "description": "The complete shell command."],
                        "folder": ["type": "string", "description": "Folder to run it in. Defaults to the home folder."]
                    ],
                    "required": ["command"]
                ],
                kind: .action,
                // The whole command, never shortened: what is approved must be what is shown.
                summarize: { input in "Terminal: \((input["command"] as? String) ?? "")" },
                tag: { input in
                    let level = CommandRisk.assess((input["command"] as? String) ?? "").level
                    return level == .safe ? ("", .neutral) : (tr("terminal.tag.review"), .caution)
                },
                run: { input in
                    let command = ((input["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !command.isEmpty else { throw NookError(tr("terminal.tool.empty")) }
                    let home = FileManager.default.homeDirectoryForCurrentUser.path
                    var folder = ((input["folder"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if folder.isEmpty { folder = home }
                    folder = (folder as NSString).expandingTildeInPath
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw NookError(tr("terminal.tool.noFolder", folder))
                    }
                    AppModel.shared.openTerminal(in: folder, command: command, title: String(command.prefix(40)))
                    return tr("terminal.tool.started", command)
                }
            )
        ]
    }
}

/// Hosts a session's terminal view in SwiftUI; the same view instance is reused, so output survives tab switches.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = true
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        container.addSubview(session.view)
        DispatchQueue.main.async { container.window?.makeFirstResponder(session.view) }
    }
}

/// Agents › Terminals: tabs for every open terminal, a new terminal in any folder, and the terminal itself.
struct TerminalsView: View {
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NookTheme.Spacing.sm) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.sm) {
                        ForEach(store.sessions) { session in
                            TerminalTab(session: session, selected: store.selected == session.id) {
                                store.selected = session.id
                            } close: {
                                store.close(session.id)
                            }
                        }
                    }
                }
                Button {
                    store.open(in: FileManager.default.homeDirectoryForCurrentUser.path)
                } label: {
                    Label(tr("workbench.terminal.new"), systemImage: "plus")
                }
                .controlSize(.small)
                Button {
                    chooseFolder()
                } label: {
                    Label(tr("workbench.terminal.inFolder"), systemImage: "folder")
                }
                .controlSize(.small)
            }
            .padding(10)
            Divider()
            if let session = store.sessions.first(where: { $0.id == store.selected }) {
                TerminalHost(session: session)
                    .id(session.id)
                    .background(Color.black)
            } else {
                WSEmptyState(
                    symbol: "terminal",
                    title: tr("workbench.terminal.emptyTitle"),
                    message: tr("workbench.terminal.emptyMessage"),
                    action: (tr("workbench.terminal.new"), { store.open(in: FileManager.default.homeDirectoryForCurrentUser.path) })
                )
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        store.open(in: url.path)
    }
}

/// The terminals of one agent session, in its folder (or worktree). With one terminal it is just the terminal: the
/// panel header above it holds + and the scripts (`SessionTerminalActions`). Tabs only show up once there are several.
/// Opening it the first time starts a terminal there, so it is ready to type in.
struct SessionTerminalsView: View {
    let directory: String
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        let mine = store.sessions(in: directory)
        let shown = mine.first { $0.id == store.selected } ?? mine.last
        VStack(spacing: 0) {
            if mine.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NookTheme.Spacing.xs) {
                        ForEach(mine) { session in
                            TerminalTab(session: session, selected: shown?.id == session.id) {
                                store.selected = session.id
                            } close: {
                                store.close(session.id)
                            }
                        }
                    }
                    .padding(.horizontal, NookTheme.Spacing.md)
                }
                .padding(.vertical, NookTheme.Spacing.xs)
                Divider()
            }
            if let shown {
                TerminalHost(session: shown)
                    .id(shown.id)
                    .background(Color.black)
            } else {
                WSEmptyState(
                    symbol: "terminal",
                    title: tr("agents.tool.noTerminal"),
                    message: AgentPathFormat.tilde(directory),
                    action: (tr("workbench.terminal.new"), { store.open(in: directory) })
                )
            }
        }
        .onAppear {
            if store.sessions(in: directory).isEmpty { store.open(in: directory) }
        }
    }
}

/// The buttons for a session's terminals, in the panel header: the project's scripts (nook.json), one click
/// each, and + for another terminal in the session's folder.
struct SessionTerminalActions: View {
    let directory: String
    @ObservedObject private var store = TerminalStore.shared
    @State private var scripts: [ProjectScript] = []

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            if !scripts.isEmpty {
                Menu {
                    ForEach(scripts) { script in
                        Button(script.name) { run(script) }
                            .help(script.command)
                    }
                } label: {
                    icon("play")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("workbench.scripts"))
                .accessibilityLabel(tr("workbench.scripts"))
            }
            Button {
                store.open(in: directory)
            } label: {
                icon("plus.rectangle")
            }
            .buttonStyle(.plain)
            .help(tr("workbench.terminal.new"))
            .accessibilityLabel(tr("workbench.terminal.new"))
        }
        .task(id: directory) {
            let folder = directory
            scripts = await Task.detached(priority: .utility) { ProjectScripts.load(folder: folder) }.value
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(NookTheme.font(11, .semibold))
            .foregroundStyle(NookTheme.textSecondary)
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
    }

    /// Runs a script in its own terminal tab; a script that serves a page opens it in Nook's browser once it had a moment.
    private func run(_ script: ProjectScript) {
        store.open(in: directory, command: script.command, title: script.name)
        guard script.autoOpenPreview, let url = script.previewURL else { return }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            BrowserStore.shared.go(url.absoluteString)
        }
    }
}

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(session.running ? NookTheme.mint : (session.exitCode == 0 ? NookTheme.textTertiary : NookTheme.coral))
                .frame(width: 5, height: 5)
            if let owner = session.owner {
                // Started by an agent: its mark, so you can tell its processes from your own shells.
                AgentMark(agent: owner.agent, account: nil, size: 11, dimmed: !session.running, ring: .clear)
                    .help(tr("bridge.terminalBy", owner.agent))
                    .accessibilityLabel(tr("bridge.terminalBy", owner.agent))
            }
            Text(session.title)
                .lineLimit(1)
                .font(selected ? NookTheme.TextStyle.label : NookTheme.TextStyle.detail)
                .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
            if !session.running, let code = session.exitCode, code != 0 {
                Text(tr("workbench.terminal.exit", code)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.coral)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(NookTheme.font(8, .bold))
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .buttonStyle(.borderless)
            .opacity(selected || hovering ? 1 : 0)
            .help(tr("workbench.terminal.close"))
            .accessibilityLabel(tr("workbench.terminal.close"))
        }
        .padding(.horizontal, NookTheme.Spacing.md)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip).fill(selected ? Color.white.opacity(0.10) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(session.owner.map { tr("bridge.terminalBy", $0.agent) + " · " + session.directory } ?? session.directory)
    }
}
