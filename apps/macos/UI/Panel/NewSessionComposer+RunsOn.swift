import SwiftUI

/// "Runs on" under the box: where the agent of a new session runs. This Mac, or one of your machines over SSH
/// (Settings › Devices › Machines), and a way to add one. Always in sight, also before any machine was added, so the
/// choice is found where a session starts instead of deep in the project menu.
extension NewSessionComposer {
    var runsOnPicker: some View {
        ComposerDropdown(width: 300) {
            ComposerPill(symbol: remoteMachine == nil ? "laptopcomputer" : "server.rack", dot: nil,
                         text: remoteMachine?.name ?? tr("ws.remote.thisMac"))
                .frame(maxWidth: 200)
        } content: {
            DropdownHeader(title: tr("ws.remote.runsOn"))
            DropdownRow(symbol: "laptopcomputer", title: tr("ws.remote.thisMac"), detail: tr("ws.remote.thisMacDetail"),
                        chosen: remoteMachine == nil) { pickThisMac() }
            ForEach(RemoteMachines.load()) { machine in
                DropdownRow(symbol: "server.rack", title: machine.name, detail: machine.host,
                            chosen: remoteMachine?.id == machine.id) { pickMachine(machine) }
            }
            DropdownDivider()
            DropdownRow(symbol: "plus", title: tr("ws.remote.add"), detail: tr("ws.remote.addDetail")) {
                app.openSettings(section: .machines)
            }
        }
        .composerTip(tr("ws.remote.runsOnHelp"))
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
}
