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
            AddMachineSheet(start: adding.start) { machine, outcome in
                RemoteMachines.upsert(machine)
                machines = RemoteMachines.load()
                ToastCenter.shared.success(tr("connection.added", machine.name))
                // The sheet's last step tested it already; otherwise test it now.
                if let outcome { record(machine, outcome) } else { test(machine) }
            }
        }
        // Again once the last machine is removed: the explanation then offers what Nook found.
        .task(id: machines.isEmpty) {
            guard machines.isEmpty else { return }
            let existing = machines
            found = await Task.detached(priority: .userInitiated) { AddMachineSheet.discover(existing: existing) }.value
        }
    }

    /// Every machine in the one connection row: its address and how its last test went on the line under its name,
    /// Test and Lock in its "…" menu with Remove last, and its details (key file, password, last use) once opened.
    private var list: some View {
        Section {
            ForEach(machines) { machine in
                let result = results[machine.id]
                ConnectionRow(title: machine.name,
                              status: testing.contains(machine.id) ? .connecting
                                  : result.map { $0.ok ? .connected : .unreachable } ?? .notLinked,
                              statusText: testing.contains(machine.id) ? tr("remote.testing")
                                  : result.map { $0.ok ? tr("remote.reachable") : tr("remote.unreachable") } ?? tr("remote.untested"),
                              detail: machine.host + (machine.port.map { ":\($0)" } ?? ""),
                              removal: ConnectionRemoval(title: tr("remote.remove"), question: tr("confirm.remove", machine.name),
                                                         detail: tr("confirm.removeMachine.detail")) {
                                  RemoteMachines.remove(id: machine.id)
                                  RemotePasswords.shared.set(nil, for: machine.id)
                                  machines = RemoteMachines.load()
                              },
                              startsOpen: askPassword.contains(machine.id)) {
                    Image(icon: "server.rack")
                        .font(NookTheme.font(16))
                        .foregroundStyle(NookTheme.textSecondary)
                } menu: {
                    Button(tr("remote.test")) { test(machine) }
                        .disabled(testing.contains(machine.id))
                    if machine.usesPassword, RemotePasswords.shared.password(for: machine.id) != nil {
                        Button(tr("remote.password.lock")) {
                            RemotePasswords.shared.set(nil, for: machine.id)
                            results[machine.id] = nil
                            machines = RemoteMachines.load()
                        }
                    }
                } expanded: {
                    if let result {
                        SettingNote(result.text, tone: result.ok ? .success : .warning)
                    }
                    if let key = machine.identityFile {
                        LabeledContent(tr("remote.keyFile")) {
                            Text(key).font(NookTheme.mono(11)).foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    if machine.usesPassword, RemotePasswords.shared.isKept(machine.id) {
                        SettingNote(tr("remote.password.inKeychain"))
                    }
                    LabeledContent(tr("remote.lastUsedTitle")) {
                        Text(machine.lastUsedAt.map { $0.formatted(.relative(presentation: .named)) } ?? tr("remote.neverUsed"))
                            .foregroundStyle(NookTheme.textSecondary)
                    }
                    if askPassword.contains(machine.id) || !RemotePasswords.shared.isUnlocked(machine) {
                        RemotePasswordField(machine: machine) { _ in
                            askPassword.remove(machine.id)
                            machines = RemoteMachines.load()
                            test(machine)
                        }
                    }
                }
            }
        } header: {
            ConnectionListHeader(title: tr("remote.title"), info: tr("remote.footer"),
                                 add: (tr("remote.add"), { adding = .blank }))
        }
    }

    /// No machine yet: what one is for, and the ones Nook found on this Mac, each one click from the form filled in.
    private var empty: some View {
        Section {
            ConnectionListEmpty(title: tr("remote.empty.title"), detail: tr("remote.empty.text"))
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
        } header: {
            ConnectionListHeader(title: tr("remote.title"), info: tr("remote.footer"),
                                 add: (tr("remote.add"), { adding = .blank }))
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
            record(machine, outcome)
            testing.remove(machine.id)
        }
    }

    /// How a test went, on the machine's row: marked used when it worked, its password field opened when it asked for one.
    private func record(_ machine: RemoteMachine, _ outcome: Probe) {
        if outcome.ok {
            RemoteMachines.markUsed(id: machine.id)
            machines = RemoteMachines.load()
        }
        if outcome.needsPassword { askPassword.insert(machine.id) } else { askPassword.remove(machine.id) }
        results[machine.id] = (outcome.ok, outcome.text)
    }

    /// What one connection test found: whether it worked, the line to show, and whether ssh asked for a password.
    typealias Probe = (ok: Bool, text: String, needsPassword: Bool)

    /// With the password typed for it in this run, if any (RemoteShell.check takes it from RemotePasswords).
    nonisolated static func probe(_ machine: RemoteMachine, commands: [String]) -> Probe {
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

/// Adding a machine in numbered steps: its address (or one found on this Mac, picked with one click), its name (which
/// follows from the address until you type one), and the connection test a session would make. Adding is possible
/// before or after a failed test; a test that ran is handed to the list, so it is not run twice.
private struct AddMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    /// A machine found on this Mac to start from.
    var start: RemoteHostDiscovery.Suggestion?
    /// The machine, and how the test in the sheet went when it ran for exactly this address.
    let add: (RemoteMachine, RemoteMachinesSection.Probe?) -> Void
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
    /// One id for the machine from the test to adding it, so a typed password and the test belong to the one added.
    @State private var machineID = UUID().uuidString
    @State private var check: SetupCheckState = .idle
    /// The last test's outcome, for the address as it is now; cleared when the address changes.
    @State private var outcome: RemoteMachinesSection.Probe?

    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var cleanIdentityFile: String { identityFile.trimmingCharacters(in: .whitespaces) }
    private var cleanHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var canAdd: Bool {
        RemoteMachines.isValidHost(cleanHost)
            && (port.trimmingCharacters(in: .whitespaces).isEmpty || portNumber != nil)
            && (cleanIdentityFile.isEmpty || RemoteMachines.isValidIdentityFile(cleanIdentityFile))
    }

    /// The machine as the form describes it now.
    private var draft: RemoteMachine {
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        return RemoteMachine(id: machineID, name: cleanName.isEmpty ? cleanHost : cleanName, host: cleanHost, port: portNumber,
                             identityFile: cleanIdentityFile.isEmpty ? nil : cleanIdentityFile)
    }

    var body: some View {
        SetupSheet(title: tr("remote.addTitle"), subtitle: tr("remote.addSubtitle"), width: 460) {
            SettingsTile(.machines, size: 40)
        } content: {
            SetupStep(number: 1, title: tr("remote.step.address"), done: canAdd) {
                if !suggestions.isEmpty {
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
                TextField(tr("remote.host"), text: $host, prompt: Text("me@buildbox.local")).textFieldStyle(.roundedBorder)
                    .font(NookTheme.TextStyle.code)
                    .onChange(of: host) { _, value in
                        resetCheck()
                        guard !namedByHand, value != filledHost else { return }
                        name = RemoteMachines.suggestedName(for: value.trimmingCharacters(in: .whitespaces))
                    }
                SettingNote(tr("remote.host"))
                DisclosureGroup(tr("remote.portAndKey")) {
                    VStack(spacing: NookTheme.Spacing.sm) {
                        TextField(tr("remote.port"), text: $port, prompt: Text("22")).textFieldStyle(.roundedBorder)
                        TextField(tr("remote.keyFile"), text: $identityFile, prompt: Text("~/.ssh/id_ed25519")).textFieldStyle(.roundedBorder)
                            .font(NookTheme.TextStyle.code)
                    }
                    .padding(.top, NookTheme.Spacing.xs)
                }
                .onChange(of: port) { _, _ in resetCheck() }
                .onChange(of: identityFile) { _, _ in resetCheck() }
                if !host.isEmpty, !RemoteMachines.isValidHost(cleanHost) {
                    SettingNote(tr("remote.badHost"), tone: .warning)
                }
                if !cleanIdentityFile.isEmpty, !RemoteMachines.isValidIdentityFile(cleanIdentityFile) {
                    SettingNote(tr("remote.badKeyFile"), tone: .warning)
                }
            }
            SetupStep(number: 2, title: tr("remote.name"), done: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                TextField(tr("remote.name"), text: Binding(get: { name }, set: { name = $0; namedByHand = true }),
                          prompt: Text("buildbox")).textFieldStyle(.roundedBorder)
            }
            SetupCheckStep(number: 3, detail: tr("remote.check.detail"), state: check, check: runCheck, disabled: !canAdd)
        } footer: {
            Spacer()
            Button(tr("button.cancel")) { dismiss() }
                .sheetCancelButton()
            Button(tr("remote.add")) {
                add(draft, outcome)
                dismiss()
            }
            .sheetPrimaryButton()
            .disabled(!canAdd || check == .checking)
        }
        .onAppear { if let start { fill(start) } }
        .task {
            let existing = RemoteMachines.load()
            suggestions = await Task.detached(priority: .userInitiated) { Self.discover(existing: existing) }.value
        }
    }

    /// One ssh login as a session would make it, the same test the list runs, before the machine is saved.
    private func runCheck() {
        let machine = draft
        let commands = AppModel.remoteAgentCommands
        check = .checking
        outcome = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                RemoteMachinesSection.probe(machine, commands: commands)
            }.value
            // The address changed while ssh ran: that answer is for the old one.
            guard draft.host == machine.host, draft.port == machine.port, draft.identityFile == machine.identityFile else { return }
            outcome = result
            if result.ok {
                check = .passed(result.text)
            } else {
                check = .failed(result.needsPassword ? tr("remote.check.needsPassword") : result.text)
            }
        }
    }

    private func resetCheck() {
        check = .idle
        outcome = nil
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
        guard let result = try? ProcessRunner.run(tool, ["status", "--json"], timeout: 4),
              result.status == 0, !result.timedOut else { return [] }
        return RemoteHostDiscovery.tailscale(result.stdoutData)
    }
}
