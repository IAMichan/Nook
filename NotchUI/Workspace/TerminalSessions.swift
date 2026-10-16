import SwiftUI
import AppKit
import SwiftTerm

/// One terminal in Nook's window: a real shell in a pseudo-terminal, started in a folder, optionally with a command.
/// Sessions stay alive while you switch tabs; closing one ends its shell.
@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    @Published var title: String
    @Published private(set) var directory: String
    /// The folder it was opened in, so it stays with that session even after a `cd` elsewhere.
    let origin: String
    @Published private(set) var exitCode: Int32?
    @Published private(set) var running = true
    let created = Date()
    let view: LocalProcessTerminalView

    init(title: String, directory: String, command: String?) {
        self.title = title
        self.directory = directory
        origin = directory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        view.processDelegate = self
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

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in if !title.isEmpty { self.title = title } }
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

/// All open terminals. Shared by the workspace, agent sessions ("Open terminal here") and account sign-in.
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selected: UUID?

    @discardableResult
    func open(in directory: String, command: String? = nil, title: String? = nil) -> TerminalSession {
        let name = title ?? URL(fileURLWithPath: directory).lastPathComponent
        let session = TerminalSession(title: name.isEmpty ? "Terminal" : name, directory: directory, command: command)
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
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
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

/// The terminals of one agent session, in its folder (or worktree): tabs when there are several, another one with +.
/// Opening it the first time starts a terminal there, so it is ready to type in.
struct SessionTerminalsView: View {
    let directory: String
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        let mine = store.sessions(in: directory)
        let shown = mine.first { $0.id == store.selected } ?? mine.last
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(mine) { session in
                            TerminalTab(session: session, selected: shown?.id == session.id) {
                                store.selected = session.id
                            } close: {
                                store.close(session.id)
                            }
                        }
                    }
                }
                Button {
                    store.open(in: directory)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(tr("workbench.terminal.new"))
                .accessibilityLabel(tr("workbench.terminal.new"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
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

private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.running ? NookTheme.mint : (session.exitCode == 0 ? NookTheme.textTertiary : NookTheme.coral))
                .frame(width: 6, height: 6)
            Text(session.title).lineLimit(1).font(.callout)
            if !session.running, let code = session.exitCode, code != 0 {
                Text(tr("workbench.terminal.exit", code)).font(.caption2).foregroundStyle(NookTheme.coral)
            }
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.white.opacity(0.12) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .help(session.directory)
    }
}
