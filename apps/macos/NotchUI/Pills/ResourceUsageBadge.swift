import SwiftUI

/// The CPU and memory a working session takes on this Mac, its agent and everything it started:
/// "34 % · 512 MB" in the session's header. Read every three seconds while the session works and is on screen; hidden
/// otherwise.
struct ResourceUsageBadge: View {
    @ObservedObject var workspace: WorkspaceManager
    let runID: UUID
    @State private var usage: ResourceUsage?

    var body: some View {
        let working = workspace.run(runID)?.status.isActive == true
        Group {
            if working, let usage {
                Text(usage.label)
                    .font(NookTheme.TextStyle.label.monospacedDigit())
                    .foregroundStyle(usage.cpuPercent > 300 ? NookTheme.amber : NookTheme.textTertiary)
                    .help(tr("ws.header.resources", usage.processes))
                    .transition(.opacity)
            }
        }
        .task(id: "\(runID)-\(working)") {
            usage = nil
            guard working else { return }
            var meter = ResourceMeter()
            while !Task.isCancelled {
                let pids = workspace.agentPIDs(runID)
                if pids.isEmpty {
                    usage = nil
                } else {
                    let tree = await Task.detached(priority: .utility) { () -> [ProcessSample] in
                        let table = ProcessTable.read()
                        var seen = Set<String>()
                        return pids.flatMap { ResourceMeter.tree(root: $0, in: table) }.filter { seen.insert($0.identity).inserted }
                    }.value
                    if let measured = meter.measure(tree, at: Date().timeIntervalSinceReferenceDate) { usage = measured }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }
}
