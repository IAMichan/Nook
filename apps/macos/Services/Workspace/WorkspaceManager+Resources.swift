import Foundation

extension WorkspaceManager {
    /// The agent processes of a session on this Mac (its turn, or the connection it keeps open), for `ResourceUsage`.
    /// None for a session on another machine: there the work happens out of reach.
    func agentPIDs(_ id: UUID) -> [Int32] {
        guard let run = run(id), !run.isRemote else { return [] }
        var pids: Set<Int32> = []
        if let process = processes[id] { pids.insert(process.pid) }
        if let server = codexServers[id] { pids.insert(server.process.pid) }
        if let idle = claudeIdle[id] { pids.insert(idle.process.pid) }
        if let client = acpClients[id] { pids.insert(client.process.pid) }
        return pids.filter { $0 > 0 }.sorted()
    }
}
