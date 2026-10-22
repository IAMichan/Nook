import Foundation

/// Keeps the programs Nook installed for you up to date, the way Nook keeps itself: shortly after launch and then once a
/// day, each only when you installed it. GOWA (the WhatsApp gateway) and the ACP agents downloaded from the registry come
/// to their newest release, with the same download and checks as installing them; Antigravity comes to the release this
/// Nook pins (the device tools do the same when the simulator next starts, see `DeviceHubService.prepare`). Nothing that
/// was not installed is installed, and a check that fails waits for the next one.
@MainActor
final class ToolUpdates {
    static let shared = ToolUpdates()

    /// Shortly after launch: not while Nook itself is starting.
    private static let firstCheck: Duration = .seconds(60)
    private static let interval: TimeInterval = 24 * 3600
    private static let lastCheckKey = "toolUpdates.lastCheck"

    private var timer: Timer?
    private var running = false

    func start() {
        guard timer == nil else { return }
        // Downloads an earlier update replaced, now that nothing runs from them.
        AcpInstaller.prune(keeping: CustomAgents.load().compactMap(\.installedAt))
        Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheck)
            await self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await ToolUpdates.shared.check() }
        }
    }

    /// At most once a day, also across launches.
    private func check() async {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard !running, Date().timeIntervalSince(last) >= Self.interval - 60 else { return }
        running = true
        defer { running = false }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        AntigravityInstaller.shared.updateIfEarlier()
        await WhatsAppGOWAInstaller.shared.update()
        await updateAcpAgents()
    }

    /// Each agent from the registry at the registry's newest version: its npx or uvx line, or a new download.
    private func updateAcpAgents() async {
        let agents = CustomAgents.load().filter { $0.registryID != nil }
        guard !agents.isEmpty, let entries = try? await AcpRegistry.fetch() else { return }
        for agent in agents {
            var updated: CustomAgent
            switch AcpRegistry.update(for: agent, in: entries) {
            case .none:
                continue
            case .runner(let runner):
                updated = runner
            case .download(let entry):
                guard let folder = try? await AcpInstaller.install(entry),
                      let downloaded = AcpRegistry.agent(from: entry, installedIn: folder, profileID: agent.profileID) else { continue }
                updated = downloaded
                updated.name = agent.name
            }
            CustomAgents.upsert(updated)
            let version = updated.version ?? ""
            Log.connectors.info("Updated the ACP agent \(agent.name) to \(version)")
        }
    }
}
