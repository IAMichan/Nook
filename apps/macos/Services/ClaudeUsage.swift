import Foundation

/// Keeps the subscription limits of every Claude account up to date, also while no session runs: the status line and the
/// `rate_limit_event` of sessions only report while Claude Code works.
///
/// Nook never touches Claude Code's login itself. It asks the official `claude` CLI, which reads its own login and answers
/// the `get_usage` control request (the numbers of `/usage`). No prompt is sent, so a reading costs no usage. The CLI runs
/// in an empty folder with only project settings, so no hooks fire and no session appears in the Agents list.
///
/// This stays within Anthropic's rules for the subscription login: the unmodified Claude Code binary signs in with the
/// user's own account, Nook never reads, stores or forwards credentials, and it asks no more often than someone typing
/// `/usage` now and then: only for signed-in accounts, every ten minutes at most, and not at all while Claude Code itself
/// reports the numbers (status line, sessions in Nook).
@MainActor
final class ClaudeUsage {
    private let hub: AgentHub
    private let profiles: () -> [AgentProfile]
    /// The `claude` executable, when Claude Code is installed.
    private let executable: () -> String?
    private var timer: Timer?
    private var lastFetch: [String: Date] = [:]
    private var busy = Set<String>()

    /// Per account this often, multiplied by the energy plan's slowdown.
    private static let interval: TimeInterval = 10 * 60
    /// `refreshNow` asks again at most this often per account: it is called on every rate limit event and while logging in.
    private static let minimumInterval: TimeInterval = 60

    init(hub: AgentHub, profiles: @escaping () -> [AgentProfile], executable: @escaping () -> String?) {
        self.hub = hub
        self.profiles = profiles
        self.executable = executable
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledCoalesced(withTimeInterval: 60) { [weak self] _ in
            Task { @MainActor in self?.refresh(after: ClaudeUsage.interval * EnergyMonitor.shared.plan.slowdown) }
        }
        refreshNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads every signed-in subscription account that was not read in the last minute: after linking, logging in or a limit event.
    func refreshNow() {
        refresh(after: Self.minimumInterval)
    }

    private func refresh(after interval: TimeInterval) {
        guard let executable = executable() else { return }
        for profile in profiles() where profile.kind == .claude && !profile.usesAPIKey {
            if let last = lastFetch[profile.id], Date().timeIntervalSince(last) < interval { continue }
            // Claude Code reported them itself just now: nothing to ask.
            if let updated = hub.subscriptionUsage(for: profile)?.updated, Date().timeIntervalSince(updated) < interval { continue }
            fetch(profile, executable: executable)
        }
    }

    private func fetch(_ profile: AgentProfile, executable: String) {
        let id = profile.id
        guard busy.insert(id).inserted else { return }
        lastFetch[id] = Date()
        let environment = profile.environment
        let home = profile.home.map(AgentProfile.normalize) ?? ""
        Task.detached(priority: .utility) { [weak self] in
            let readings = ClaudeUsage.read(executable: executable, environment: environment)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.busy.remove(id)
                // Not signed in with a subscription, or offline: keep what was shown and try again next time.
                if let readings { self.hub.applyPlanReadings(readings, home: home) }
            }
        }
    }

    // MARK: Background work

    /// Starts `claude` in stream-json mode, sends `get_usage` and reads the reply. Gives up after 20 seconds.
    private nonisolated static func read(executable: String, environment extra: [String: String]) -> [UsageLimits.PlanReading]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                             "--no-session-persistence", "--setting-sources", "project"]
        // An empty folder of its own, so no project settings or hooks come along.
        process.currentDirectoryURL = NookPaths.brainScratchDirectory
        var env = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: executable, extra: extra)
        env["NOOK_INTERNAL"] = "1"
        process.environment = env
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { if process.isRunning { process.terminate() } }

        // Terminating closes stdout, which ends the read loop.
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel() }

        let request = #"{"type":"control_request","request_id":"nook-usage","request":{"subtype":"get_usage","skip_behaviors":true}}"#
        input.fileHandleForWriting.write(Data((request + "\n").utf8))
        // Claude Code answers pending control requests and then exits once its input ends.
        try? input.fileHandleForWriting.close()

        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      (object["type"] as? String) == "control_response",
                      let response = object["response"] as? [String: Any],
                      (response["request_id"] as? String) == "nook-usage" else { continue }
                guard (response["subtype"] as? String) == "success",
                      let body = response["response"] as? [String: Any] else { return nil }
                return UsageLimits.claudeUsageReply(body)
            }
        }
    }
}
