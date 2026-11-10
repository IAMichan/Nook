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
    let id: UUID
    /// The split it shows in: the terminals of one group sit side by side or stacked (`TerminalStore.split`). A terminal
    /// opened on its own is a group of one, with its own id.
    let group: UUID
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

    init(title: String, directory: String, command: String?, shortID: String = "", owner: TerminalOwner? = nil,
         group: UUID? = nil) {
        let id = UUID()
        self.id = id
        self.group = group ?? id
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
        // Clicking into a pane of a split makes it the active terminal: the one the buttons split and close.
        view.focused = { TerminalStore.shared.activate(id) }
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

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

    /// Called once when its shell ends, with the exit code (a cleanup script's terminal closes when it succeeds).
    var onExit: ((Int32?) -> Void)?

    /// The shell's process id, 0 before it started.
    var shellPID: Int32 { view.process?.shellPid ?? 0 }

    /// The shell waits for input: nothing runs in it, in the foreground or in the background. A terminal still busy
    /// with its startup command (a dev server) has that command as a child, so it is not idle.
    var idleAtPrompt: Bool {
        let shell = shellPID
        guard running, shell > 0, ProcessTree.children(of: shell).isEmpty else { return false }
        let terminal = view.process?.childfd ?? -1
        return terminal < 0 || tcgetpgrp(terminal) == shell
    }

    /// Stops what runs in the terminal, with everything it started: each process group below the shell, or only the
    /// process where that group must live on (Nook's, an agent's). Then the shell ends.
    func stopProcesses() {
        let shell = shellPID
        guard running, shell > 0 else { return close() }
        let protected = ProcessTree.protectedGroups()
        var stopped: Set<ProcessTree.StopTarget> = []
        for pid in ProcessTree.descendants(of: shell, children: ProcessTree.children(of:)).reversed() {
            let target = ProcessTree.stopTarget(pid: pid, group: ProcessTree.group(of: pid), protectedGroups: protected)
            if stopped.insert(target).inserted { ProcessTree.stop(target) }
        }
        close()
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
            let exit = self.onExit
            self.onExit = nil
            exit?(exitCode)
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
    /// Called when you click into the terminal.
    var focused: @MainActor () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        MainActor.assumeIsolated { focused() }
        super.mouseDown(with: event)
    }

    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        let base = MainActor.assumeIsolated { linkBase() }
        let text = link.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if TerminalLinks.isURL(text), let url = URL(string: text) {
                if TerminalLinks.isLocal(url) {
                    BrowserStore.show(url)
                } else {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            // The terminal's own match can carry sentence punctuation; read it the way the link parser does.
            let path = TerminalLinks.extract(text).first { $0.kind == .path }?.text ?? text
            guard let target = FileLink.parse(path), let resolved = FileLink.resolve(target, base: base) else { return }
            AppModel.shared.openFileInNook(resolved, beside: false)
        }
    }
}

/// How the terminals of one group share their room: next to each other, or one above the other.
enum TerminalSplit: Equatable {
    case sideBySide, stacked

    var symbol: String { self == .sideBySide ? "rectangle.split.2x1" : "rectangle.split.1x2" }
}

/// All open terminals. Shared by the workspace, agent sessions ("Open terminal here") and account sign-in.
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()
    /// At most this many terminals share one split, so each keeps a usable width.
    static let maxPerGroup = 4
    /// Every terminal, the members of a group kept together in the order they were split.
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selected: UUID?
    /// How each group with more than one terminal is split; a group without an entry is side by side.
    @Published private(set) var splits: [UUID: TerminalSplit] = [:]
    private var opened = 0

    @discardableResult
    func open(in directory: String, command: String? = nil, title: String? = nil, owner: TerminalOwner? = nil) -> TerminalSession {
        let session = make(in: directory, command: command, title: title, owner: owner, group: nil)
        sessions.append(session)
        selected = session.id
        return session
    }

    /// Opens another terminal in `id`'s folder beside it (`.sideBySide`) or under it (`.stacked`), in the same group;
    /// nil when that group is full (`maxPerGroup`).
    @discardableResult
    func split(_ id: UUID, _ split: TerminalSplit) -> TerminalSession? {
        guard let source = sessions.first(where: { $0.id == id }), members(of: source.group).count < Self.maxPerGroup else {
            return nil
        }
        if splits[source.group] != split { splits[source.group] = split }
        let session = make(in: source.origin, command: nil, title: nil, owner: nil, group: source.group)
        let after = sessions.lastIndex { $0.group == source.group } ?? sessions.count - 1
        sessions.insert(session, at: after + 1)
        selected = session.id
        return session
    }

    /// The terminals of a group, in their order on screen.
    func members(of group: UUID) -> [TerminalSession] {
        sessions.filter { $0.group == group }
    }

    /// Makes `id` the active terminal, without a write when it already is (it is called on every focus).
    func activate(_ id: UUID) {
        if selected != id { selected = id }
    }

    private func make(in directory: String, command: String?, title: String?, owner: TerminalOwner?, group: UUID?) -> TerminalSession {
        let name = title ?? URL(fileURLWithPath: directory).lastPathComponent
        opened += 1
        return TerminalSession(title: name.isEmpty ? "Terminal" : name, directory: directory, command: command,
                               shortID: "t\(opened)", owner: owner, group: group)
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

    /// Stops what runs in a terminal (and what that started), then takes it away like `close`.
    func stop(_ id: UUID) {
        sessions.first { $0.id == id }?.stopProcesses()
        close(id)
    }

    /// Opens a terminal that goes away by itself when its command succeeds; when it fails it stays, with the error.
    @discardableResult
    func openClosingOnSuccess(in directory: String, command: String, title: String) -> TerminalSession {
        let session = open(in: directory, command: command, title: title)
        let id = session.id
        session.onExit = { [weak self] code in if code == 0 { self?.close(id) } }
        return session
    }

    /// Ends a terminal's shell and takes it away. When it was the active one, the next of its split takes over, so the
    /// split stays in view; with none left, the last terminal.
    func close(_ id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        session.close()
        sessions.removeAll { $0.id == id }
        let rest = members(of: session.group)
        if rest.isEmpty { splits[session.group] = nil }
        if selected == id { selected = rest.last?.id ?? sessions.last?.id }
    }
}

/// A container that never asks for a size of its own: the terminal fills whatever SwiftUI gives it. A terminal view that
/// reports an intrinsic size makes the window re-run its layout again and again.
private final class TerminalContainer: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

extension TerminalStore {
    /// The one way Nook's brain touches a shell: it proposes a command, the user approves the whole command in the plan,
    /// and it runs in a visible terminal next to the chat, so output and errors can be read there. There is no read-only
    /// variant and no hidden execution.
    var tools: [ToolSpec] {
        [
            ToolSpec(
                name: "run_command",
                description: "Runs a shell command in a visible terminal of Nook, next to the chat, in an optional folder. Use it only when the user asks for something that needs a command line; the user approves the exact command first and sees its output in the terminal.",
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
                    AppModel.shared.openTerminalBesideChat(in: folder, command: command, title: String(command.prefix(40)))
                    return tr("terminal.tool.started", command)
                }
            )
        ]
    }
}

/// Hosts a session's terminal view in SwiftUI; the same view instance is reused, so output survives tab switches.
/// `focus`: it takes the keyboard when it appears (the active pane of a split), if the panel takes focus at all.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    var focus = true

    func makeNSView(context: Context) -> NSView {
        let container = TerminalContainer()
        attach(to: container, focus: focus && context.environment.sidePanelTakesFocus)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(to: container, focus: focus && context.environment.sidePanelTakesFocus) }
    }

    private func attach(to container: NSView, focus: Bool) {
        session.view.removeFromSuperview()
        session.view.translatesAutoresizingMaskIntoConstraints = true
        session.view.frame = container.bounds
        session.view.autoresizingMask = [.width, .height]
        container.addSubview(session.view)
        if focus { DispatchQueue.main.async { container.window?.makeFirstResponder(session.view) } }
    }
}

enum TerminalMetrics {
    /// The list of terminals beside the panes, once there are several.
    static let list: CGFloat = 150
    /// A row in that list, and a group's header above its rows.
    static let row: CGFloat = 24
    static let groupHeader: CGFloat = 22
    /// A button of the bordered action group (`TerminalActionBar`).
    static let action = CGSize(width: 26, height: 22)
}

/// Terminals in one room: the active terminal's split fills it, its panes side by side or stacked with a line between
/// them, and once there are several terminals a narrow list of them on the right, grouped by split. Clicking a pane
/// makes it the active one; the list switches between splits. The same in Agents › Terminals, beside a session, and
/// beside the chat.
struct TerminalDeck: View {
    let terminals: [TerminalSession]
    @ObservedObject private var store = TerminalStore.shared
    @State private var closing: TerminalSession?

    var body: some View {
        let active = Self.active(in: terminals, store: store)
        HStack(spacing: 0) {
            if let active {
                TerminalPanes(terminals: terminals.filter { $0.group == active.group },
                              split: store.splits[active.group] ?? .sideBySide, active: active.id)
            }
            if terminals.count > 1 {
                NookDivider(vertical: true)
                TerminalList(terminals: terminals, active: active?.id) { closing = $0 }
                    .frame(width: TerminalMetrics.list)
            }
        }
        .confirmCloseTerminal($closing)
    }

    /// The terminal the buttons act on: the selected one when it is among `terminals`, else the newest.
    static func active(in terminals: [TerminalSession], store: TerminalStore) -> TerminalSession? {
        terminals.first { $0.id == store.selected } ?? terminals.last
    }
}

/// The panes of one split, sharing the room equally, with a line between them.
private struct TerminalPanes: View {
    let terminals: [TerminalSession]
    let split: TerminalSplit
    let active: UUID

    var body: some View {
        let layout = split == .stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        layout {
            ForEach(Array(terminals.enumerated()), id: \.element.id) { index, terminal in
                if index > 0 { NookDivider(vertical: split == .sideBySide) }
                TerminalHost(session: terminal, focus: terminal.id == active)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The list beside the panes: every terminal, those of a split under a quiet header that names how it is split.
private struct TerminalList: View {
    let terminals: [TerminalSession]
    let active: UUID?
    let close: (TerminalSession) -> Void
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        let groups = Self.groups(terminals)
        let headers = groups.contains { $0.count > 1 }
        ScrollView {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                ForEach(groups, id: \.first!.group) { group in
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                        if headers {
                            TerminalGroupHeader(count: group.count, split: group.count > 1 ? store.splits[group[0].group] ?? .sideBySide : nil,
                                                active: group.contains { $0.id == active }) {
                                store.activate((group.first { $0.id == active } ?? group[0]).id)
                            }
                        }
                        ForEach(group) { terminal in
                            TerminalRow(session: terminal, selected: terminal.id == active) {
                                store.activate(terminal.id)
                            } close: {
                                close(terminal)
                            }
                        }
                    }
                    .padding(.bottom, headers ? NookTheme.Spacing.xs : 0)
                }
            }
            .padding(NookTheme.Spacing.xs)
        }
    }

    /// The terminals per split, in the order the splits were first opened.
    static func groups(_ terminals: [TerminalSession]) -> [[TerminalSession]] {
        var order: [UUID] = []
        var members: [UUID: [TerminalSession]] = [:]
        for terminal in terminals {
            if members[terminal.group] == nil { order.append(terminal.group) }
            members[terminal.group, default: []].append(terminal)
        }
        return order.compactMap { members[$0] }
    }
}

/// Above a split's rows: how it is split and how many terminals it holds; a click shows that split.
private struct TerminalGroupHeader: View {
    let count: Int
    /// nil for a terminal on its own.
    let split: TerminalSplit?
    let active: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: NookTheme.Spacing.xs) {
                Image(systemName: split?.symbol ?? "square")
                    .font(NookTheme.font(10, .medium))
                Text(tr(split == nil ? "terminal.group.single" : (split == .stacked ? "terminal.group.stacked" : "terminal.group.sideBySide")))
                    .lineLimit(1)
                Spacer(minLength: NookTheme.Spacing.xs)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(active || hovering ? NookTheme.textStrong : NookTheme.textTertiary)
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: TerminalMetrics.groupHeader)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(hovering ? NookTheme.rowHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
    }
}

/// One terminal in the list: its mark, its name and how it ended, with a cross at the end (under the pointer) that closes it.
/// A right click offers the folder and closing as well.
private struct TerminalRow: View {
    @ObservedObject var session: TerminalSession
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "terminal")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                if let owner = session.owner {
                    // Started by an agent: its mark, so you can tell its processes from your own shells.
                    AgentMark(agent: owner.agent, account: nil, size: 11, dimmed: !session.running, ring: .clear)
                        .help(tr("bridge.terminalBy", owner.agent))
                        .accessibilityLabel(tr("bridge.terminalBy", owner.agent))
                }
                Text(session.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
                Spacer(minLength: 0)
                if !session.running {
                    Circle()
                        .fill(session.exitCode == 0 ? NookTheme.textTertiary : NookTheme.coral)
                        .frame(width: 5, height: 5)
                        .help(session.exitCode.map { tr("workbench.terminal.exit", $0) } ?? "")
                }
                // Always takes its room, so the name does not move when the cross appears.
                Color.clear.frame(width: 14, height: 14)
            }
            .padding(.horizontal, NookTheme.Spacing.sm)
            .frame(height: TerminalMetrics.row)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.chip, style: .continuous)
                .fill(NookTheme.rowFill(selected: selected, hovering: hovering, rest: .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(NookTheme.font(9, .semibold))
                    .foregroundStyle(NookTheme.paper)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, NookTheme.Spacing.sm)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help(tr("workbench.terminal.close"))
            .accessibilityLabel(tr("workbench.terminal.close"))
        }
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .contextMenu {
            Button(tr("agents.panel.copyPath")) { Pasteboard.copy(session.directory) }
            Button(tr("ws.outputs.reveal")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.directory)])
            }
            Divider()
            Button(tr("workbench.terminal.close"), role: .destructive, action: close)
        }
        .help(session.owner.map { tr("bridge.terminalBy", $0.agent) + " · " + session.directory } ?? session.directory)
    }
}

/// The terminal's own buttons as one bordered group, a line between each: split right, split down, a new terminal, and
/// close the active one (after asking). Splitting stops at `TerminalStore.maxPerGroup` per split.
struct TerminalActionBar: View {
    let terminals: [TerminalSession]
    let newTerminal: () -> Void
    @ObservedObject private var store = TerminalStore.shared
    @State private var closing: TerminalSession?

    var body: some View {
        let active = TerminalDeck.active(in: terminals, store: store)
        let full = active.map { store.members(of: $0.group).count >= TerminalStore.maxPerGroup } ?? true
        let limit = tr("terminal.split.limit", TerminalStore.maxPerGroup)
        HStack(spacing: 0) {
            TerminalActionButton(symbol: TerminalSplit.sideBySide.symbol,
                                 label: active != nil && full ? limit : tr("terminal.split.right"), enabled: !full) {
                if let active { store.split(active.id, .sideBySide) }
            }
            NookDivider(vertical: true)
            TerminalActionButton(symbol: TerminalSplit.stacked.symbol,
                                 label: active != nil && full ? limit : tr("terminal.split.down"), enabled: !full) {
                if let active { store.split(active.id, .stacked) }
            }
            NookDivider(vertical: true)
            TerminalActionButton(symbol: "plus", label: tr("workbench.terminal.new"), action: newTerminal)
            NookDivider(vertical: true)
            TerminalActionButton(symbol: "trash", label: tr("workbench.terminal.close"), enabled: active != nil) {
                closing = active
            }
        }
        .frame(height: TerminalMetrics.action.height)
        .clipShape(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous)
            .strokeBorder(NookTheme.border, lineWidth: 1))
        .fixedSize()
        .confirmCloseTerminal($closing)
    }
}

/// A button of `TerminalActionBar`: a quiet symbol that brightens, on a fill, under the pointer.
private struct TerminalActionButton: View {
    let symbol: String
    let label: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(!enabled ? NookTheme.textTertiary.opacity(0.5) : (hovering ? NookTheme.paper : NookTheme.textSecondary))
                .frame(width: TerminalMetrics.action.width, height: TerminalMetrics.action.height)
                .background(hovering && enabled ? NookTheme.smoke : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

private extension View {
    /// Asks before a terminal is closed: its shell and whatever runs in it stop, and its output is gone.
    func confirmCloseTerminal(_ terminal: Binding<TerminalSession?>) -> some View {
        confirmDelete(terminal, question: { tr("terminal.close.question", $0.title) },
                      detail: tr("terminal.close.detail"), confirmTitle: tr("workbench.terminal.close")) {
            TerminalStore.shared.close($0.id)
        }
    }
}

/// Agents › Terminals: every open terminal, a new one in any folder, and the terminals themselves.
struct TerminalsView: View {
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SidePanelToolbar {
                Button {
                    chooseFolder()
                } label: {
                    Label(tr("workbench.terminal.inFolder"), systemImage: "folder")
                }
                .controlSize(.small)
                Spacer(minLength: NookTheme.Spacing.md)
                TerminalActionBar(terminals: store.sessions) { store.open(in: FileManager.default.homeDirectoryForCurrentUser.path) }
            }
            if store.sessions.isEmpty {
                WSEmptyState(
                    symbol: "terminal",
                    title: tr("workbench.terminal.emptyTitle"),
                    message: tr("workbench.terminal.emptyMessage"),
                    action: (tr("workbench.terminal.new"), { store.open(in: FileManager.default.homeDirectoryForCurrentUser.path) })
                )
            } else {
                TerminalDeck(terminals: store.sessions)
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

/// The terminals of one agent session, in its folder (or worktree). The bar above it (`SessionTerminalBar`) holds the
/// buttons; the list beside the panes only shows up once there are several. Opening it the first time starts a
/// terminal there, so it is ready to type in.
struct SessionTerminalsView: View {
    let directory: String
    @ObservedObject private var store = TerminalStore.shared

    var body: some View {
        let mine = store.sessions(in: directory)
        Group {
            if mine.isEmpty {
                WSEmptyState(
                    symbol: "terminal",
                    title: tr("agents.tool.noTerminal"),
                    message: AgentPathFormat.tilde(directory),
                    action: (tr("workbench.terminal.new"), { store.open(in: directory) })
                )
            } else {
                TerminalDeck(terminals: mine)
            }
        }
        .onAppear {
            if store.sessions(in: directory).isEmpty { store.open(in: directory) }
        }
    }
}

/// The bar under a terminal panel's header, so the panes keep the panel's full width: the terminal's folder and its
/// actions. The same beside a session and beside the chat.
struct SessionTerminalBar: View {
    let directory: String

    var body: some View {
        Group {
            Image(systemName: "folder")
                .font(NookTheme.font(10, .medium))
                .foregroundStyle(NookTheme.textTertiary)
            Text(AgentPathFormat.tilde(directory))
                .font(NookTheme.mono(11))
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(directory)
            Spacer(minLength: NookTheme.Spacing.md)
            SessionTerminalActions(directory: directory).id(directory)
        }
    }
}

/// A terminal next to the chat (a command the chat ran): the side panel a session's terminal has, with the same header,
/// folder bar and terminals, so it looks and works the same as in Agents.
struct ChatTerminalPanel: View {
    let directory: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidePanelHeader(closeHelp: tr("workbench.terminal.close"), close: close) {
                SidePanelTitle(symbol: SessionTool.terminal.symbol, title: SessionTool.terminal.title)
            }
            SidePanelToolbar { SessionTerminalBar(directory: directory) }
            SessionTerminalsView(directory: directory).id(directory)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The buttons for a session's terminals: the project's scripts (nook.json), one click each, and the terminal's action
/// group (split, new in the session's folder, close).
struct SessionTerminalActions: View {
    let directory: String
    @ObservedObject private var store = TerminalStore.shared
    @State private var scripts: [ProjectScript] = []

    var body: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if !scripts.isEmpty {
                Menu {
                    ForEach(scripts) { script in
                        Button(script.name) { run(script) }
                            .help(script.command)
                    }
                } label: {
                    Image(systemName: "play")
                        .font(NookTheme.font(11, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                        .frame(width: TerminalMetrics.action.width, height: TerminalMetrics.action.height)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(tr("workbench.scripts"))
                .accessibilityLabel(tr("workbench.scripts"))
            }
            TerminalActionBar(terminals: store.sessions(in: directory)) { store.open(in: directory) }
        }
        .task(id: directory) {
            let folder = directory
            scripts = await Task.detached(priority: .utility) { ProjectScripts.load(folder: folder) }.value
        }
    }

    /// Runs a script in its own terminal; a script that serves a page opens it in Nook's browser once it had a moment.
    private func run(_ script: ProjectScript) {
        store.open(in: directory, command: script.command, title: script.name)
        guard script.autoOpenPreview, let url = script.previewURL else { return }
        let browser = SessionBrowsers.shared.inView
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            browser.go(url.absoluteString)
        }
    }
}
