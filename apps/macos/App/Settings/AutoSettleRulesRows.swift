import SwiftUI

/// The auto-settle rules in Settings › Sessions, for all machines at once or for one: this Mac or an SSH machine, as
/// t3code sets them per environment. A machine without rules of its own follows the ones for all machines; a change for
/// all machines goes to the machines with their own rules too, and the rows say which machines have them ("Mixed").
struct AutoSettleRulesRows: View {
    @ObservedObject private var inbox = InboxStore.shared
    /// Empty: all machines. Otherwise `AutoSettlePolicy.thisMac` or a `RemoteMachine.id`.
    @State private var scope = ""
    @State private var machines: [RemoteMachine] = []

    var body: some View {
        Group {
            if !machines.isEmpty {
                Picker(tr("settings.ws.autoSettleScope"), selection: $scope) {
                    Text(tr("settings.ws.autoSettleScope.all")).tag("")
                    Text(tr("settings.ws.autoSettleScope.thisMac")).tag(AutoSettlePolicy.thisMac)
                    ForEach(machines) { machine in Text(machine.name).tag(machine.id) }
                }
                if !scope.isEmpty {
                    Toggle(tr("settings.ws.autoSettleScope.own"), isOn: ownRules)
                }
            }
            Group {
                Toggle(tr("settings.ws.autoSettle"), isOn: rule(\.enabled))
                if rules.enabled {
                    Toggle(tr("settings.ws.autoSettleMerged"), isOn: rule(\.settleOnMergedPullRequest))
                    Toggle(tr("settings.ws.autoSettleClosed"), isOn: rule(\.settleOnClosedPullRequest))
                    Stepper(tr("settings.ws.autoSettleDays", rules.inactivityDays), value: rule(\.inactivityDays), in: 1...30)
                    Toggle(tr("settings.ws.autoSettleKeepOpenPR"), isOn: rule(\.keepWithOpenPullRequest))
                        .help(tr("settings.ws.autoSettleKeepOpenPR.help"))
                }
            }
            .disabled(followsAll)
            if scope.isEmpty, !ownNames.isEmpty {
                Text(tr("settings.ws.autoSettleScope.mixed", ownNames.joined(separator: ", ")))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { machines = RemoteMachines.load() }
    }

    /// The rules the rows show: the ones for all machines, or the selected machine's (its own, else the ones it follows).
    private var rules: AutoSettlePolicy.Settings {
        scope.isEmpty ? inbox.autoSettle : inbox.autoSettleRules(machine: scope)
    }

    /// A machine without rules of its own: its rows show what it follows and change only after "Own rules".
    private var followsAll: Bool { !scope.isEmpty && inbox.autoSettleByMachine[scope] == nil }

    private var ownRules: Binding<Bool> {
        Binding(get: { inbox.autoSettleByMachine[scope] != nil }, set: { own in
            if own { inbox.setAutoSettle(\.enabled, to: inbox.autoSettle.enabled, machine: scope) } else { inbox.followAllMachines(scope) }
        })
    }

    private func rule<Value>(_ field: WritableKeyPath<AutoSettlePolicy.Settings, Value>) -> Binding<Value> {
        Binding(get: { rules[keyPath: field] }, set: { inbox.setAutoSettle(field, to: $0, machine: scope.isEmpty ? nil : scope) })
    }

    /// The machines with rules of their own that differ from the ones for all machines, by name.
    private var ownNames: [String] {
        let all = inbox.autoSettle
        let differing = inbox.autoSettleByMachine.filter { key, own in
            var own = own
            own.perThreadOptOut = all.perThreadOptOut
            return own != all
        }.keys
        return differing.sorted().compactMap { key in
            key == AutoSettlePolicy.thisMac ? tr("settings.ws.autoSettleScope.thisMac") : machines.first { $0.id == key }?.name
        }
    }
}
