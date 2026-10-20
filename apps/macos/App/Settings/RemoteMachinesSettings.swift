import SwiftUI

/// Settings › Agents › Workspace › Machines: the machines sessions can run on over SSH (see RemoteMachines). Nook uses
/// your own `ssh`, so an alias from ~/.ssh/config works, and so does a key in your SSH agent. A connection test shows at
/// once whether a session would start.
struct RemoteMachinesSection: View {
    @State private var machines = RemoteMachines.load()
    @State private var adding = false
    @State private var results: [String: String] = [:]
    @State private var testing: Set<String> = []

    var body: some View {
        Section {
            if machines.isEmpty {
                Text(tr("remote.empty")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
            }
            ForEach(machines) { machine in
                HStack(spacing: 10) {
                    Image(systemName: "server.rack").foregroundStyle(NookTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(machine.name).font(NookTheme.font(13, .medium))
                        Text(machine.host + (machine.port.map { ":\($0)" } ?? ""))
                            .font(NookTheme.mono(11))
                            .foregroundStyle(NookTheme.textSecondary)
                        if let result = results[machine.id] {
                            Text(result).font(NookTheme.TextStyle.detail).foregroundStyle(result == tr("remote.test.ok") ? NookTheme.mint : NookTheme.amber)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if testing.contains(machine.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(tr("remote.test")) { test(machine) }
                    }
                    ConfirmedButton(symbol: "trash", title: tr("button.delete"), question: tr("confirm.remove", machine.name),
                                    detail: tr("confirm.removeMachine.detail")) {
                        RemoteMachines.remove(id: machine.id)
                        machines = RemoteMachines.load()
                    }
                    .labelled(tr("button.delete"))
                    .buttonStyle(.borderless)
                    .help(tr("remote.remove"))
                }
            }
            Button { adding = true } label: { Label(tr("remote.add"), systemImage: "plus") }
        } header: {
            Text(tr("remote.title"))
        } footer: {
            Text(tr("remote.footer"))
        }
        .sheet(isPresented: $adding) {
            AddMachineSheet { machine in
                RemoteMachines.upsert(machine)
                machines = RemoteMachines.load()
                test(machine)
            }
        }
    }

    /// `ssh -o BatchMode=yes host true`: without a password prompt, as a session would connect.
    private func test(_ machine: RemoteMachine) {
        testing.insert(machine.id)
        results[machine.id] = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { Self.probe(machine) }.value
            results[machine.id] = outcome
            testing.remove(machine.id)
        }
    }

    nonisolated private static func probe(_ machine: RemoteMachine) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: RemoteLaunch.ssh)
        var arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]
        if let port = machine.port { arguments += ["-p", String(port)] }
        process.arguments = arguments + ["--", machine.host, "true"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do { try process.run() } catch { return error.localizedDescription }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: stop)
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        if process.terminationStatus == 0 { return tr("remote.test.ok") }
        let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? tr("remote.test.failed", Int(process.terminationStatus)) : String(message.prefix(300))
    }
}

private struct AddMachineSheet: View {
    @Environment(\.dismiss) private var dismiss
    let add: (RemoteMachine) -> Void
    @State private var name = ""
    @State private var host = ""
    @State private var port = ""

    private var portNumber: Int? { Int(port.trimmingCharacters(in: .whitespaces)).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canAdd: Bool {
        RemoteMachines.isValidHost(host.trimmingCharacters(in: .whitespaces))
            && (port.trimmingCharacters(in: .whitespaces).isEmpty || portNumber != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(tr("remote.addTitle")).font(NookTheme.TextStyle.heading)
            Text(tr("remote.addSubtitle")).foregroundStyle(NookTheme.textSecondary)
            TextField(tr("remote.name"), text: $name, prompt: Text("buildbox")).textFieldStyle(.roundedBorder)
            TextField(tr("remote.host"), text: $host, prompt: Text("me@buildbox.local")).textFieldStyle(.roundedBorder)
                .font(NookTheme.TextStyle.code)
            TextField(tr("remote.port"), text: $port, prompt: Text("22")).textFieldStyle(.roundedBorder)
            if !host.isEmpty, !RemoteMachines.isValidHost(host.trimmingCharacters(in: .whitespaces)) {
                Text(tr("remote.badHost")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
            }
            HStack {
                Spacer()
                Button(tr("button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("remote.add")) {
                    let cleanHost = host.trimmingCharacters(in: .whitespaces)
                    let cleanName = name.trimmingCharacters(in: .whitespaces)
                    add(RemoteMachine(name: cleanName.isEmpty ? cleanHost : cleanName, host: cleanHost, port: portNumber))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
