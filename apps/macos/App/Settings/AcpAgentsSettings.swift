import SwiftUI

/// Settings › Agents › Accounts › ACP: the agents you added beyond the ones Nook knows by name. Pick one from the ACP
/// registry, or enter its command yourself, from "+ Add ACP agent" in the section's header. Each becomes an account
/// ("ACP · Kiro") you can start sessions with, shown in the connection row every list in Settings uses; removing it
/// (from its "…" menu, after asking) removes that account from Nook and deletes a copy Nook downloaded for it.
struct AcpAgentsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var agents = CustomAgents.load()
    @State private var showRegistry = false
    @State private var showManual = false
    /// The agent just added: its row opens by itself.
    @State private var justAdded: String?

    var body: some View {
        Section {
            if agents.isEmpty {
                ConnectionListEmpty(title: tr("acp.empty.title"), detail: tr("acp.empty.detail"))
            }
            ForEach(agents) { agent in
                let commandLine = ([agent.command] + agent.arguments).joined(separator: " ")
                ConnectionRow(title: agent.name, version: agent.version, status: .connected,
                              statusText: tr(agent.installedAt == nil ? "acp.state.added" : "acp.state.installed"),
                              detail: commandLine,
                              removal: ConnectionRemoval(title: tr("acp.removeAgent"), question: tr("confirm.remove", agent.name),
                                                         detail: tr("acp.remove.detail")) { remove(agent) },
                              startsOpen: agent.id == justAdded) {
                    AgentLogo(agent: agent.name, size: 22)
                } expanded: {
                    // What runs, in full: the agent is a program from the internet, started through your login shell.
                    LabeledContent(tr("acp.manual.command")) {
                        Text(commandLine)
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                    if let folder = agent.installedAt {
                        LabeledContent(tr("acp.folder")) {
                            Text(AgentProfile.tildePath(folder))
                                .font(NookTheme.mono(11))
                                .foregroundStyle(NookTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    SettingNote(tr("acp.footer"))
                }
            }
        } header: {
            ConnectionListMenuHeader(title: tr("acp.title"), info: tr("acp.footer"), add: tr("acp.addAgent")) {
                Button { showRegistry = true } label: { Label(tr("acp.fromRegistry"), systemImage: "square.grid.2x2") }
                Button { showManual = true } label: { Label(tr("acp.manual"), systemImage: "terminal") }
            }
        }
        .sheet(isPresented: $showRegistry) {
            AcpRegistrySheet { entry, folder in
                add(name: entry.name) { profile in
                    if let folder { return AcpRegistry.agent(from: entry, installedIn: folder, profileID: profile) }
                    return AcpRegistry.agent(from: entry, profileID: profile)
                }
            }
        }
        .sheet(isPresented: $showManual) {
            AcpManualSheet { name, command, arguments in
                add(name: name) { CustomAgent(profileID: $0, name: name, command: command, arguments: arguments) }
            }
        }
    }

    /// A new ACP account for the agent, then the agent itself, then a fresh scan so it shows up everywhere.
    private func add(name: String, _ make: (String) -> CustomAgent?) {
        let profile = app.profiles.add(kind: .acp, label: name)
        guard let agent = make(profile.id) else {
            app.profiles.remove(profile.id)
            return
        }
        CustomAgents.upsert(agent)
        agents = CustomAgents.load()
        justAdded = agent.id
        app.history.refresh(minimumInterval: 0)
        ToastCenter.shared.success(tr("connection.added", agent.name))
    }

    private func remove(_ agent: CustomAgent) {
        if let folder = agent.installedAt { AcpInstaller.uninstall(folder) }
        CustomAgents.remove(profileID: agent.profileID)
        app.profiles.remove(agent.profileID)
        agents = CustomAgents.load()
        app.history.refresh(minimumInterval: 0)
        ToastCenter.shared.success(tr("connection.removed", agent.name))
    }
}

/// The ACP registry: search, then add. An agent the registry offers only as a download is installed first (checked
/// against its SHA-256); the folder it was installed in comes along with it.
private struct AcpRegistrySheet: View {
    @Environment(\.dismiss) private var dismiss
    let add: (AcpRegistry.Entry, String?) -> Void
    @State private var installing = false
    @State private var installError: String?
    @State private var entries: [AcpRegistry.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var query = ""
    @State private var chosen: AcpRegistry.Entry?

    private var shown: [AcpRegistry.Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let list = needle.isEmpty ? entries : entries.filter {
            $0.name.lowercased().contains(needle) || $0.id.contains(needle) || $0.description.lowercased().contains(needle)
        }
        return list.sorted { ($0.isSupported ? 0 : 1, $0.name.lowercased()) < ($1.isSupported ? 0 : 1, $1.name.lowercased()) }
    }

    var body: some View {
        // The one sheet shape: what this is on top, the searchable list in the middle, Cancel and Add below.
        SetupSheet(title: tr("acp.registry.title"), subtitle: tr("acp.registry.subtitle")) {
            SettingsTile(.agents, size: 40)
        } content: {
            // Two steps, as every add sheet: pick the agent, then check what Nook will run or download for it.
            SetupStep(number: 1, title: tr("acp.step.pick"), done: chosen != nil) {
                NookSearchField(prompt: tr("acp.registry.search"), text: $query, style: .inline)
                if loading {
                    PatientSpinner().frame(maxWidth: .infinity, minHeight: 200)
                } else if let error {
                    SettingNote(error, tone: .warning)
                } else {
                    VStack(spacing: NookTheme.Spacing.xxs) {
                        ForEach(shown) { entry in
                            SettingsPickRow(title: entry.name, detail: registryDetail(entry), selected: chosen?.id == entry.id) {
                                chosen = entry
                            }
                            .disabled(!entry.isSupported)
                            .opacity(entry.isSupported ? 1 : 0.5)
                        }
                    }
                }
            }
            // What will run or be downloaded, before you add it: the agent is a program from the internet. Installing a
            // download is the check: its SHA-256 must match.
            SetupCheckStep(number: 2, title: tr("acp.step.check"), detail: checkDetail, state: checkState)
        } footer: {
            if installing {
                ProgressView().controlSize(.small)
                Text(tr("acp.install.busy")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            }
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button(chosen?.command == nil && chosen?.binary != nil ? tr("acp.install") : tr("acp.add")) { confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!(chosen?.isSupported ?? false) || installing)
        }
        .interactiveDismissDisabled(installing)
        .task {
            do {
                entries = try await AcpRegistry.fetch()
                if entries.isEmpty { error = tr("acp.registry.emptyList") }
            } catch let failure {
                error = tr("acp.registry.failed", failure.localizedDescription)
            }
            loading = false
        }
    }

    private var checkDetail: String {
        if let chosen, let command = chosen.command {
            return tr("acp.registry.runs", ([command] + chosen.arguments).joined(separator: " "))
        }
        if let chosen, let binary = chosen.binary {
            return tr("acp.registry.downloads", binary.archive.absoluteString, String(binary.sha256.prefix(12)) + "…")
        }
        return tr("acp.step.checkHint")
    }

    private var checkState: SetupCheckState {
        if installing { return .checking }
        if let installError { return .failed(installError) }
        return .idle
    }

    /// The line under an agent in the list: its version, how it comes, and what it does.
    private func registryDetail(_ entry: AcpRegistry.Entry) -> String {
        var parts = [entry.version]
        if entry.command == nil, entry.binary != nil {
            parts.append(tr("acp.registry.download"))
        } else if !entry.isSupported {
            parts.append(tr("acp.registry.unavailable"))
        }
        if !entry.description.isEmpty { parts.append(entry.description) }
        return parts.joined(separator: " · ")
    }

    /// npx and uvx agents are added at once; a download is installed first, and the sheet stays until that is done.
    private func confirm() {
        guard let chosen else { return }
        guard chosen.command == nil, chosen.binary != nil else {
            add(chosen, nil)
            dismiss()
            return
        }
        installing = true
        installError = nil
        Task {
            do {
                let folder = try await AcpInstaller.install(chosen)
                add(chosen, folder)
                dismiss()
            } catch {
                installError = error.localizedDescription
            }
            installing = false
        }
    }
}

/// An ACP agent by hand: a name, the command that starts its ACP server, and Nook checks that the program is there.
private struct AcpManualSheet: View {
    @Environment(\.dismiss) private var dismiss
    let add: (String, String, [String]) -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var check: SetupCheckState = .idle

    private var parsed: (command: String, arguments: [String])? { CustomAgents.parseCommand(command) }
    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && parsed != nil }

    var body: some View {
        SetupSheet(title: tr("acp.manual.title"), subtitle: tr("acp.manual.subtitle"), width: 460) {
            SettingsTile(.agents, size: 40)
        } content: {
            // Three steps, as every add sheet: what to call it, the command that starts its ACP server, and the check.
            SetupStep(number: 1, title: tr("acp.manual.name"), done: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                TextField("", text: $name, prompt: Text(tr("acp.manual.namePlaceholder"))).textFieldStyle(.roundedBorder)
            }
            SetupStep(number: 2, title: tr("acp.manual.command"), done: parsed != nil) {
                TextField("", text: $command, prompt: Text("npx -y @vendor/agent-acp@1.0.0"))
                    .textFieldStyle(.roundedBorder)
                    .font(NookTheme.TextStyle.code)
                    .onChange(of: command) { _, _ in check = .idle }
                if !command.isEmpty, parsed == nil {
                    SettingNote(tr("acp.manual.badCommand"), tone: .warning)
                }
            }
            SetupCheckStep(number: 3, title: tr("acp.manual.checkTitle"), detail: tr("acp.manual.checkDetail"), state: check,
                           check: runCheck, disabled: parsed == nil)
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            // A program Nook could not find is still added: it may only be on the PATH of the shell sessions start in.
            Button(tr("acp.add")) {
                if let parsed { add(name.trimmingCharacters(in: .whitespaces), parsed.command, parsed.arguments) }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAdd)
        }
    }

    /// Looks the program up the way a session starts it, through your login shell (nvm, Homebrew, asdf), off the main
    /// thread.
    private func runCheck() {
        guard let program = parsed?.command else { return }
        check = .checking
        Task {
            let path = await Self.locate(program)
            // The command changed while Nook looked: that answer is for the old one.
            guard parsed?.command == program else { return }
            if let path {
                check = .passed(tr("acp.manual.found", AgentProfile.tildePath(path)))
            } else {
                check = .failed(tr("acp.manual.notFound", program))
            }
        }
    }

    /// The full path of `program`: a path as typed when it is executable, else what `command -v` says in the login shell.
    nonisolated static func locate(_ program: String) async -> String? {
        await Task.detached { () -> String? in
            if program.contains("/") {
                let path = (program as NSString).expandingTildeInPath
                return FileManager.default.isExecutableFile(atPath: path) ? path : nil
            }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard let output = try? ProcessRunner.run(shell, ["-lc", "command -v " + TerminalLauncher.shellQuote(program)], timeout: 15),
                  output.status == 0 else { return nil }
            let path = output.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            return path.hasPrefix("/") ? path : nil
        }.value
    }
}
