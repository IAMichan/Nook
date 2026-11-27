import Foundation
import Combine

/// Whether each machine over SSH answers now, and which agents it has: the dot beside a machine under "Runs on" and what
/// "Automatic" (`MachineBalance`) may pick from. Nothing polls: a machine is asked when "Runs on" opens and right before
/// an automatic start, and an answer counts for two minutes, so an idle Nook asks nothing.
@MainActor
final class MachineReachability: ObservableObject {
    static let shared = MachineReachability()

    enum Status: Equatable {
        case unknown
        case checking
        /// It let you in; the agents' commands found on its PATH.
        case online(agents: [String])
        /// A password is needed and none was typed in this run of Nook.
        case locked
        case offline(String)

        var isOnline: Bool { if case .online = self { return true } else { return false } }
    }

    @Published private(set) var statuses: [String: Status] = [:]
    private var checkedAt: [String: Date] = [:]
    private var running: [String: Task<Void, Never>] = [:]
    /// How long an answer counts.
    static let freshFor: TimeInterval = 120

    func status(_ id: String) -> Status { statuses[id] ?? .unknown }

    /// Asks every machine whose answer is older than two minutes; the ones already asking are left alone.
    func refresh(_ machines: [RemoteMachine], force: Bool = false) {
        for machine in machines { check(machine, force: force) }
    }

    /// Asks the machines and waits (at most about 25 seconds each, in parallel) until each has answered.
    func refreshAndWait(_ machines: [RemoteMachine]) async {
        refresh(machines)
        for machine in machines { await running[machine.id]?.value }
    }

    private func check(_ machine: RemoteMachine, force: Bool) {
        guard running[machine.id] == nil else { return }
        if !force, let at = checkedAt[machine.id], Date().timeIntervalSince(at) < Self.freshFor, statuses[machine.id] != nil { return }
        guard RemotePasswords.shared.isUnlocked(machine) else {
            set(machine.id, .locked)
            return
        }
        set(machine.id, .checking)
        let commands = AppModel.remoteAgentCommands
        let password = RemotePasswords.shared.password(for: machine.id)
        running[machine.id] = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                RemoteShell.check(machine, password: password, commands: commands)
            }.value
            guard let self else { return }
            switch result {
            case .success(let found):
                self.set(machine.id, .online(agents: found))
                RemoteMachines.markUsed(id: machine.id)
            case .failure(let failure):
                self.set(machine.id, failure.needsPassword ? .locked : .offline(failure.message))
            }
            self.checkedAt[machine.id] = Date()
            self.running[machine.id] = nil
        }
    }

    /// Published only when it changed, so the composer does not redraw for the same answer.
    private func set(_ id: String, _ status: Status) {
        if statuses[id] != status { statuses[id] = status }
    }
}
