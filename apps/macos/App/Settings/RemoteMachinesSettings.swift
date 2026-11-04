import SwiftUI

/// Settings › Machines: the machines sessions can run on over SSH (see RemoteMachines). Nook uses
/// your own `ssh`, so an alias from ~/.ssh/config works, and so does a key in your SSH agent or a key file per machine. A
/// connection test shows at once whether a session would start, and which agents that machine has. A machine that only
/// takes a password gets a field for it here (see RemotePasswordField), kept in memory until Nook quits, or in the
/// Keychain when you chose that; Lock forgets it in both.
struct RemoteMachinesSection: View {
    @State private var machines = RemoteMachines.load()
    /// The Add sheet, open: on a machine found on this Mac, or empty (`Adding.blank`).
    @State private var adding: Adding?
    /// Machines from ~/.ssh/config, ~/.ssh/known_hosts and your tailnet, offered while none is added yet.
    @State private var found: [RemoteHostDiscovery.Suggestion] = []
    @ObservedObject private var pageAction = SettingsPageAction.shared

    private struct Adding: Identifiable {
        let id = UUID()
        var start: RemoteHostDiscovery.Suggestion?
        static var blank: Adding { Adding(start: nil) }
    }
    @State private var results: [String: (ok: Bool, text: String)] = [:]
    @State private var testing: Set<String> = []
    /// Machines whose last test was turned away for want of a password.
    @State private var askPassword: Set<String> = []

    var body: some View {
        // The explanation while there is no machine, the list once there is; never an empty list under a heading.
        Group {
            if machines.isEmpty {
                empty
            } else {
                list
            }
        }
        .sheet(item: $adding) { adding in
            AddMachineSheet(start: adding.start) { machine in
                RemoteMachines.upsert(machine)
                machines = RemoteMachines.load()
                test(machine)
            }
        }
        // The header's "Add machine" button.
        .onAppear { act(pageAction.requested) }
        .onChange(of: pageAction.requested) { _, section in act(section) }
        // Again once the last machine is removed: the explanation then offers what Nook found.
        .task(id: machines.isEmpty) {
            guard machines.isEmpty else { return }
            let existing = machines
            found = await Task.detached(priority: .userInitiated) { AddMachineSheet.discover(existing: existing) }.value
        }
    }

    /// Every machine with what its last test said, and Lock, Test and Remove.
    private var list: some View {
        Section {
            ForEach(machines) { machine in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Image(systemName: "server.rack").foregroundStyle(NookTheme.textSecondary)
                        VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                            Text(machine.name).font(NookTheme.TextStyle.strong)
                            Text(machine.host + (machine.port.map { ":\($0)" } ?? ""))
                                .font(NookTheme.mono(11))
                                .foregroundStyle(NookTheme.textSecondary)
                            if let key = machine.identityFile {
                                Text(tr("remote.keyFile.shown", key))
                                    .font(NookTheme.mono(11))
                                    .foregroundStyle(NookTheme.textSecondary)
                            }
                            if machine.usesPassword, RemotePasswords.shared.isKept(machine.id) {
                                Text(tr("remote.password.inKeychain"))
                                    .font(NookTheme.TextStyle.detail)
                                    .foregroundStyle(NookTheme.textSecondary)
                            }
                            Text(machine.lastUsedAt.map { tr("remote.lastUsed", $0.formatted(.relative(presentation: .named))) }
                                 ?? tr("remote.neverUsed"))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textSecondary)
                            if let result = results[machine.id] {
                                SettingNote(result.text, tone: result.ok ? .success : .warning)
                            }
                        }
                        Spacer()
                        if machine.usesPassword, RemotePasswords.shared.password(for: machine.id) != nil {
                            Button(tr("remote.password.lock")) {
                                RemotePasswords.shared.set(nil, for: machine.id)
                                results[machine.id] = nil
                                machines = RemoteMachines.load()
                            }
                            .help(tr("remote.password.lock.help"))
                        }
                        if testing.contains(machine.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(tr("remote.test")) { test(machine) }
                        }
                        ConfirmedButton(symbol: "trash", title: tr("remote.remove"), question: tr("confirm.remove", machine.name),
                                        detail: tr("confirm.removeMachine.detail")) {
                            RemoteMachines.remove(id: machine.id)
                            RemotePasswords.shared.set(nil, for: machine.id)
                            machines = RemoteMachines.load()
                        }
                        .labelled(tr("remote.remove"))
                        .buttonStyle(.borderless)
                    }
                    if askPassword.contains(machine.id) || !RemotePasswords.shared.isUnlocked(machine) {
                        RemotePasswordField(machine: machine) { _ in
                            askPassword.remove(machine.id)
                            machines = RemoteMachines.load()
                            test(machine)
                        }
                        .padding(.leading, NookTheme.Spacing.xxl)
                    }
                }
            }
        } header: {
            SettingsSectionTitle(tr("remote.title"), info: tr("remote.footer"))
        }
    }

    private func act(_ section: SettingsSection?) {
        guard section == .machines else { return }
        pageAction.requested = nil
        adding = .blank
    }

    /// No machine yet: what one is for, and the ones Nook found on this Mac, each one click from the form filled in.
    private var empty: some View {
        Section {
            IntroCard(title: tr("remote.empty.title"), text: tr("remote.empty.text"))
            if !found.isEmpty {
                Text(tr("remote.found"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                ForEach(found.prefix(6)) { suggestion in
                    LabeledContent {
                        Button(tr("remote.addThis")) { adding = Adding(start: suggestion) }
                            .controlSize(.small)
                    } label: {
                        SettingLabel(suggestion.name, detail: [suggestion.host, tr("remote.suggestion." + suggestion.source.rawValue)]
                            .joined(separator: " · "))
                    }
                }
            }
        }
    }

    /// One ssh login as a session would connect (with the password typed in this run, or else never prompting), that
    /// also looks for the agents' CLIs in the login shell there.
    private func test(_ machine: RemoteMachine) {
        testing.insert(machine.id)
        results[machine.id] = nil
        let commands = AppModel.remoteAgentCommands
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Self.probe(machine, commands: commands) }.value
            if outcome.ok {
                RemoteMachines.markUsed(id: machine.id)
                machines = RemoteMachines.load()
            }
            if outcome.needsPassword { askPassword.insert(machine.id) } else { askPassword.remove(machine.id) }
            results[machine.id] = (outcome.ok, outcome.text)
            testing.remove(machine.id)
        }
    }

    /// With the password typed for it in this run, if any (RemoteShell.check takes it from RemotePasswords).
    nonisolated private static func probe(_ machine: RemoteMachine, commands: [String]) -> (ok: Bool, text: String, needsPassword: Bool) {
        switch RemoteShell.check(machine, password: nil, commands: commands) {
        case .success(let found):
            let names = AppModel.agentNames(found)
            return (true, names.isEmpty ? tr("remote.test.noAgents") : tr("remote.test.agents", names.joined(separator: ", ")), false)
        case .failure(let error):
            if error.needsPassword { return (false, tr("remote.password.needed", machine.name), true) }
            return (false, error.message.isEmpty ? tr("remote.test.failed", Int(error.status)) : error.message, false)
        }
    }
}

/// Adding a machine: the ones found on this Mac to pick with one click, then only its address (the name follows from it
/// until you type one), with the port and key file folded away. Adding tests the connection at once.
private struct AddMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// A machine found on this Mac to start from.
    var start: RemoteHostDiscovery.Suggestion?
    let add: (RemoteMachine) -> Void
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""
    @State private var identityFile = ""
    /// You typed a name yourself: the address no longer fills it in.
    @State private var namedByHand = false
    /// The address a picked suggestion filled in, which keeps the suggestion's own name until the address changes.
    @State private var filledHost: String?
    /// Machines from ~/.ssh/config, ~/.ssh/known_hosts and your tailnet, to fill the form with one click.
    @State private var suggestions: [RemoteHostDiscovery.Suggestion] = []

    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var cleanIdentityFile: String { identityFile.trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool {
        RemoteMachines.isValidHost(host.trimmingCharacters(in: .whitespaces))
            && (port.trimmingCharacters(in: .whitespaces).isEmpty || portNumber != nil)
            && (cleanIdentityFile.isEmpty || RemoteMachines.isValidIdentityFile(cleanIdentityFile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            Text(tr("remote.addTitle")).font(NookTheme.TextStyle.heading)
            Text(tr("remote.addSubtitle")).foregroundStyle(NookTheme.textSecondary)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    Text(tr("remote.found"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                    ScrollView {
                        VStack(spacing: NookTheme.Spacing.xxs) {
                            ForEach(suggestions) { suggestion in
                                SettingsPickRow(title: suggestion.name,
                                                detail: [suggestion.host, tr("remote.suggestion." + suggestion.source.rawValue)].joined(separator: " · "),
                                                selected: host == suggestion.host) { fill(suggestion) }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            TextField(tr("remote.host"), text: $host, prompt: Text("me@buildbox.local")).textFieldStyle(.roundedBorder)
                .font(NookTheme.TextStyle.code)
                .onChange(of: host) { _, value in
                    guard !namedByHand, value != filledHost else { return }
                    name = RemoteMachines.suggestedName(for: value.trimmingCharacters(in: .whitespaces))
                }
            TextField(tr("remote.name"), text: Binding(get: { name }, set: { name = $0; namedByHand = true }),
                      prompt: Text("buildbox")).textFieldStyle(.roundedBorder)
            DisclosureGroup(tr("settings.display.advanced")) {
                VStack(spacing: NookTheme.Spacing.sm) {
                    TextField(tr("remote.port"), text: $port, prompt: Text("22")).textFieldStyle(.roundedBorder)
                    TextField(tr("remote.keyFile"), text: $identityFile, prompt: Text("~/.ssh/id_ed25519")).textFieldStyle(.roundedBorder)
                        .font(NookTheme.TextStyle.code)
                }
                .padding(.top, NookTheme.Spacing.xs)
            }
            if !host.isEmpty, !RemoteMachines.isValidHost(host.trimmingCharacters(in: .whitespaces)) {
                SettingNote(tr("remote.badHost"), tone: .warning)
            }
            if !cleanIdentityFile.isEmpty, !RemoteMachines.isValidIdentityFile(cleanIdentityFile) {
                SettingNote(tr("remote.badKeyFile"), tone: .warning)
            }
            HStack {
                Spacer()
                Button(tr("button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("remote.add")) {
                    let cleanHost = host.trimmingCharacters(in: .whitespaces)
                    let cleanName = name.trimmingCharacters(in: .whitespaces)
                    add(RemoteMachine(name: cleanName.isEmpty ? cleanHost : cleanName, host: cleanHost, port: portNumber,
                                      identityFile: cleanIdentityFile.isEmpty ? nil : cleanIdentityFile))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(NookTheme.Spacing.xxl)
        .frame(width: 460)
        .onAppear { if let start { fill(start) } }
        .task {
            let existing = RemoteMachines.load()
            suggestions = await Task.detached(priority: .userInitiated) { Self.discover(existing: existing) }.value
        }
    }

    private func fill(_ suggestion: RemoteHostDiscovery.Suggestion) {
        filledHost = suggestion.host
        host = suggestion.host
        name = suggestion.name
        namedByHand = false
        port = suggestion.port.map(String.init) ?? ""
    }

    /// Reads ~/.ssh/config (and the files it includes) and ~/.ssh/known_hosts, and asks the Tailscale app for the devices of your tailnet. Nothing
    /// is contacted on the network.
    nonisolated static func discover(existing: [RemoteMachine]) -> [RemoteHostDiscovery.Suggestion] {
        let home = NSHomeDirectory()
        let ssh = (home as NSString).appendingPathComponent(".ssh")
        let include: (String) -> [String] = { pattern in
            RemoteHostDiscovery.includedFiles(pattern, sshDirectory: ssh, home: home)
                .compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
        let config = (try? String(contentsOfFile: ssh + "/config", encoding: .utf8))
            .map { RemoteHostDiscovery.sshConfig($0, include: include) } ?? []
        let known = (try? String(contentsOfFile: ssh + "/known_hosts", encoding: .utf8)).map(RemoteHostDiscovery.knownHosts) ?? []
        return RemoteHostDiscovery.merge(tailscale: tailnet(), sshConfig: config, knownHosts: known, existing: existing)
    }

    /// `tailscale status --json`, from the app or a command line install; nothing when Tailscale is not there or not up.
    nonisolated private static func tailnet() -> [RemoteHostDiscovery.Suggestion] {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["status", "--json"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return [] }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 4, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        return process.terminationStatus == 0 ? RemoteHostDiscovery.tailscale(data) : []
    }
}
