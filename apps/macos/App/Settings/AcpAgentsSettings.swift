import SwiftUI

/// Settings › Agents › Accounts › ACP: the agents you added beyond the ones Nook knows by name. Pick one from the ACP registry, or enter its command yourself. Each becomes an account ("ACP · Kiro") you can
/// start sessions with; removing it removes that account from Nook (its folder stays).
struct AcpAgentsSection: View {
    @EnvironmentObject private var app: AppModel
    @State private var agents = CustomAgents.load()
    @State private var showRegistry = false
    @State private var showManual = false

    var body: some View {
        Section {
            if agents.isEmpty {
                Text(tr("acp.empty"))
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(agents) { agent in
                HStack(spacing: 10) {
                    AgentLogo(agent: agent.name, size: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name).font(NookTheme.font(13, .medium))
                        Text(([agent.command] + agent.arguments).joined(separator: " "))
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if let version = agent.version {
                        Text(version).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                    }
                    Button(role: .destructive) { remove(agent) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help(tr("acp.remove"))
                }
            }
            HStack {
                Button { showRegistry = true } label: { Label(tr("acp.fromRegistry"), systemImage: "square.grid.2x2") }
                Button { showManual = true } label: { Label(tr("acp.manual"), systemImage: "terminal") }
            }
        } header: {
            HStack(spacing: 8) {
                AgentLogo(.acp, size: 16)
                Text(tr("acp.title"))
            }
        } footer: {
            Text(tr("acp.footer"))
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
        app.history.refresh(minimumInterval: 0)
    }

    private func remove(_ agent: CustomAgent) {
        if let folder = agent.installedAt { AcpInstaller.uninstall(folder) }
        CustomAgents.remove(profileID: agent.profileID)
        app.profiles.remove(agent.profileID)
        agents = CustomAgents.load()
        app.history.refresh(minimumInterval: 0)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("acp.registry.title")).font(NookTheme.TextStyle.heading)
            Text(tr("acp.registry.subtitle")).foregroundStyle(NookTheme.textSecondary)
            TextField(tr("acp.registry.search"), text: $query).textFieldStyle(.roundedBorder)
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(NookTheme.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown, selection: Binding<String?>(get: { chosen?.id }, set: { id in chosen = entries.first { $0.id == id } })) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(entry.name).font(NookTheme.font(13, .medium))
                                Text(entry.version).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                                if entry.command == nil, entry.binary != nil {
                                    Text(tr("acp.registry.download")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                                } else if !entry.isSupported {
                                    Text(tr("acp.registry.unavailable")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
                                }
                            }
                            if !entry.description.isEmpty {
                                Text(entry.description).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(2)
                            }
                        }
                        .tag(entry.id)
                        .opacity(entry.isSupported ? 1 : 0.5)
                    }
                }
            }
            .frame(minHeight: 280)
            if let chosen, let command = chosen.command {
                // What will run, before you add it: the agent is a program from the internet.
                Text(tr("acp.registry.runs", ([command] + chosen.arguments).joined(separator: " ")))
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textSecondary)
                    .textSelection(.enabled)
            } else if let chosen, let binary = chosen.binary {
                Text(tr("acp.registry.downloads", binary.archive.absoluteString, String(binary.sha256.prefix(12)) + "…"))
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textSecondary)
                    .textSelection(.enabled)
            }
            if let installError {
                Text(installError).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
            }
            HStack {
                if installing {
                    ProgressView().controlSize(.small)
                    Text(tr("acp.install.busy")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
                }
                Spacer()
                Button(tr("button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(chosen?.command == nil && chosen?.binary != nil ? tr("acp.install") : tr("acp.add")) { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(chosen?.isSupported ?? false) || installing)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
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

/// An ACP agent by hand: a name and the command that starts its ACP server.
private struct AcpManualSheet: View {
    @Environment(\.dismiss) private var dismiss
    let add: (String, String, [String]) -> Void
    @State private var name = ""
    @State private var command = ""

    private var parsed: (command: String, arguments: [String])? { CustomAgents.parseCommand(command) }
    private var canAdd: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && parsed != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("acp.manual.title")).font(NookTheme.TextStyle.heading)
            Text(tr("acp.manual.subtitle")).foregroundStyle(NookTheme.textSecondary)
            TextField(tr("acp.manual.name"), text: $name).textFieldStyle(.roundedBorder)
            TextField(tr("acp.manual.command"), text: $command, prompt: Text("npx -y @vendor/agent-acp@1.0.0"))
                .textFieldStyle(.roundedBorder)
                .font(NookTheme.TextStyle.code)
            if !command.isEmpty, parsed == nil {
                Text(tr("acp.manual.badCommand")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
            }
            HStack {
                Spacer()
                Button(tr("button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("acp.add")) {
                    if let parsed { add(name.trimmingCharacters(in: .whitespaces), parsed.command, parsed.arguments) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
