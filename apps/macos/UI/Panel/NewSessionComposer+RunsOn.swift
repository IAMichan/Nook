import SwiftUI

/// "Runs on" under the box: where the agent of a new session runs. This Mac, one of your machines over SSH (Settings ›
/// Devices › Machines) with a dot for whether it answers, "Automatic" (`MachineBalance`) once a machine exists, and a
/// way to add one. Always in sight, so the choice is found where a session starts.
extension NewSessionComposer {
    var runsOnPicker: some View {
        RunsOnPicker(chosen: remoteMachine, automatic: autoPlace,
                     onThisMac: { autoPlace = false; pickThisMac() },
                     onMachine: { autoPlace = false; pickMachine($0) },
                     onAutomatic: { pickThisMac(); autoPlace = true },
                     onAdd: { app.openSettings(section: .machines) })
    }

    /// Back from a machine to this Mac: the folder chosen here before, else the project you used last. What you typed
    /// goes along, as it does when you pick a folder.
    func pickThisMac() {
        guard remoteMachine != nil else { return }
        let path = config.projectPath.isEmpty ? settings.lastProject : config.projectPath
        if path.isEmpty {
            remoteMachine = nil
        } else {
            pick(path)
        }
    }

    /// Whether "Automatic" decides where this session starts: only for a project on this Mac (a folder of its own
    /// for "No project" always stays here) and not while comparing models, which needs worktrees here.
    var startsAutomatically: Bool {
        autoPlace && remoteMachine == nil && !config.projectPath.isEmpty && !ScratchProjects.isScratch(config.projectPath)
            && comparing.isEmpty
    }

    /// Where "Automatic" starts `request`: the machine it picked, with the project's folder there, or this Mac (nil).
    /// Asks the shared machines first (at most about 25 seconds, in parallel).
    func automaticPlace(for request: NewRunConfig) async -> RemoteTarget? {
        let project = request.projectPath
        let machines = MachineBalance.sharedMachines(RemoteMachines.load(), project: project)
            .filter { $0.balanceLevel != .manualOnly }
        guard !machines.isEmpty else { return nil }
        let reachability = MachineReachability.shared
        await reachability.refreshAndWait(machines)
        let command = request.provider.kind.command
        let active = workspace.runs.filter { $0.status.isActive }
        var candidates = [MachineBalance.Candidate(
            machineID: nil, level: LocalBalance.level(), active: active.filter { $0.remote == nil }.count,
            available: app.connectedProviders(in: project).contains(request.provider))]
        for machine in machines {
            let agents: [String]
            if case .online(let found) = reachability.status(machine.id) { agents = found } else { agents = [] }
            candidates.append(MachineBalance.Candidate(
                machineID: machine.id, level: machine.balanceLevel,
                active: active.filter { $0.remote?.machineID == machine.id }.count,
                available: agents.contains(command)))
        }
        guard let id = MachineBalance.pick(candidates), let machine = machines.first(where: { $0.id == id }),
              let folder = machine.folder(for: project) else { return nil }
        return RemoteTarget(machine: machine, directory: folder)
    }

    /// Keeps the folder a session of this Mac's project used on a machine: the project is then shared with it, and
    /// "Automatic" may start it there.
    func rememberSharedFolder(_ remote: RemoteTarget, project: String) {
        guard !project.isEmpty, !ScratchProjects.isScratch(project) else { return }
        RemoteMachines.update(id: remote.machineID) { $0.remember(folder: remote.directory, for: project) }
    }
}

/// The picker itself, a view of its own so only it redraws when a machine's dot changes.
struct RunsOnPicker: View {
    let chosen: RemoteMachine?
    let automatic: Bool
    let onThisMac: () -> Void
    let onMachine: (RemoteMachine) -> Void
    let onAutomatic: () -> Void
    let onAdd: () -> Void
    @ObservedObject private var reachability = MachineReachability.shared

    var body: some View {
        let machines = RemoteMachines.load()
        ComposerDropdown(width: 300) {
            ComposerPill(symbol: chosen != nil ? "server.rack" : automatic ? "scale.3d" : "laptopcomputer",
                         dot: chosen.map { dot(reachability.status($0.id)) } ?? nil,
                         text: chosen?.name ?? (automatic ? tr("ws.remote.auto") : tr("ws.remote.thisMac")))
                .frame(maxWidth: 200)
        } content: {
            DropdownHeader(title: tr("ws.remote.runsOn"))
            if !machines.isEmpty {
                DropdownRow(symbol: "scale.3d", title: tr("ws.remote.auto"), detail: tr("ws.remote.autoDetail"),
                            chosen: automatic && chosen == nil, action: onAutomatic)
            }
            DropdownRow(symbol: "laptopcomputer", title: tr("ws.remote.thisMac"), detail: tr("ws.remote.thisMacDetail"),
                        chosen: chosen == nil && !automatic, action: onThisMac)
            ForEach(machines) { machine in
                DropdownRow(symbol: "server.rack", title: machine.name, detail: detail(machine),
                            chosen: chosen?.id == machine.id, tint: tint(reachability.status(machine.id))) { onMachine(machine) }
            }
            DropdownDivider()
            DropdownRow(symbol: "plus", title: tr("ws.remote.add"), detail: tr("ws.remote.addDetail"), action: onAdd)
                // Opening the menu asks the machines whose answer is older than two minutes; nothing polls.
                .onAppear { reachability.refresh(machines) }
        }
        .composerTip(tr("ws.remote.runsOnHelp"))
    }

    /// The machine's address, then how it answered.
    private func detail(_ machine: RemoteMachine) -> String {
        let address = machine.host + (machine.port.map { ":\($0)" } ?? "")
        switch reachability.status(machine.id) {
        case .unknown: return address
        case .checking: return address + " · " + tr("ws.remote.status.checking")
        case .online: return address + " · " + tr("ws.remote.status.online")
        case .locked: return address + " · " + tr("ws.remote.status.locked")
        case .offline: return address + " · " + tr("ws.remote.status.offline")
        }
    }

    /// State colors keep their meaning: mint answers, amber waits on you or is asking, coral does not answer.
    private func dot(_ status: MachineReachability.Status) -> Color? {
        switch status {
        case .unknown: return nil
        case .checking, .locked: return NookTheme.amber
        case .online: return NookTheme.mint
        case .offline: return NookTheme.coral
        }
    }

    private func tint(_ status: MachineReachability.Status) -> Color? {
        if case .offline = status { return NookTheme.textTertiary }
        return nil
    }
}
