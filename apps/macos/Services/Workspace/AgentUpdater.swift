import Foundation

/// The agent programs Settings › Agents can update (see `AgentUpdates`): what installed each, the newest version, and an
/// update while it runs. Nothing here runs by itself: the newest versions are looked up when Settings shows the list (at
/// most every half hour), and an update only after you confirmed it (`AppModel+AgentUpdates`).
@MainActor
final class AgentUpdater: ObservableObject {
    static let shared = AgentUpdater()

    enum Phase: Equatable {
        case idle
        /// Running; the last line the installer printed.
        case updating(String)
        case updated
        case failed(String)

        var isBusy: Bool { if case .updating = self { return true } else { return false } }
    }

    struct Entry: Equatable {
        var provider: RunProvider
        var executable: String
        var owner: AgentInstallOwner
        var command: AgentUpdateCommand?
        var latest: String?
        var phase: Phase = .idle
    }

    @Published private(set) var entries: [RunProvider: Entry] = [:]
    /// The agents waiting for you to confirm their update; Settings › Agents asks.
    @Published var pending: [RunProvider]?

    /// Said when an update ended: the agent, whether it worked, and the installer's last words.
    var onFinished: ((RunProvider, Bool, String) -> Void)?

    private var checked: [RunProvider: (path: String, at: Date)] = [:]
    private static let checkSeconds: TimeInterval = 30 * 60
    private static let updateTimeout: TimeInterval = 10 * 60

    /// Reads who owns each agent's program (`executables`: the agent and its program's path) and looks up the newest
    /// versions that are due. Agents without a program drop out.
    func scan(_ executables: [(RunProvider, String)], force: Bool = false) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen: Set<RunProvider> = []
        for (provider, path) in executables where AgentUpdates.updatable(provider) {
            seen.insert(provider)
            let resolved = RenderedPageFile.realPath(path) ?? path
            let owner = AgentUpdates.owner(of: provider, resolved: resolved, home: home)
            var entry = entries[provider] ?? Entry(provider: provider, executable: path, owner: owner)
            entry.executable = path
            entry.owner = owner
            entry.command = AgentUpdates.command(for: owner, executable: path)
            if entries[provider] != entry { entries[provider] = entry }
            let now = Date()
            if !force, let last = checked[provider], last.path == path, now.timeIntervalSince(last.at) < Self.checkSeconds { continue }
            checked[provider] = (path, now)
            guard let source = AgentUpdates.latestSource(for: provider, owner: owner) else { continue }
            Task { [weak self] in
                let latest = await Self.latest(source)
                guard let self, let latest, var current = self.entries[provider], current.latest != latest else { return }
                current.latest = latest
                self.entries[provider] = current
            }
        }
        for provider in entries.keys where !seen.contains(provider) && entries[provider]?.phase.isBusy != true {
            entries[provider] = nil
        }
    }

    /// The agents that have an update and a command to run it, given their installed versions.
    func outdated(installed: [RunProvider: String]) -> [RunProvider] {
        RunProvider.allCases.filter { provider in
            guard let entry = entries[provider], entry.command != nil, !entry.phase.isBusy else { return false }
            return AgentUpdates.isOutdated(installed: installed[provider], latest: entry.latest)
        }
    }

    /// Runs the updates one after another (two installers writing one npm prefix at once can break both).
    func update(_ providers: [RunProvider]) {
        let jobs = providers.compactMap { provider -> (RunProvider, AgentUpdateCommand, String)? in
            guard var entry = entries[provider], let command = entry.command, !entry.phase.isBusy else { return nil }
            entry.phase = .updating("")
            entries[provider] = entry
            return (provider, command, entry.executable)
        }
        guard !jobs.isEmpty else { return }
        Task { [weak self] in
            for (provider, command, executable) in jobs {
                let result = await Self.run(command, agent: executable) { line in
                    Task { @MainActor [weak self] in self?.setPhase(.updating(line), provider, onlyWhileBusy: true) }
                }
                guard let self else { return }
                self.setPhase(result.ok ? .updated : .failed(result.last), provider)
                self.checked[provider] = nil
                self.onFinished?(provider, result.ok, result.last)
            }
        }
    }

    private func setPhase(_ phase: Phase, _ provider: RunProvider, onlyWhileBusy: Bool = false) {
        guard var entry = entries[provider], entry.phase != phase else { return }
        if onlyWhileBusy, !entry.phase.isBusy { return }
        entry.phase = phase
        entries[provider] = entry
    }

    // MARK: Off the main thread

    private nonisolated static func latest(_ source: AgentLatestSource) async -> String? {
        switch source {
        case .npm(let package):
            guard let url = AgentUpdates.npmDistTagsURL(package),
                  let (data, response) = try? await NetworkGuard.fetch(url), response.statusCode == 200 else { return nil }
            return AgentUpdates.parseNpmDistTags(data)
        case .homebrew(let brew, let name, let cask):
            return await Task.detached(priority: .utility) {
                let command = AgentUpdateCommand(executable: brew, arguments: ["info", "--json=v2"] + (cask ? ["--cask"] : []) + [name])
                guard let output = capture(command, agent: brew, timeout: 60), output.status == 0 else { return nil }
                return AgentUpdates.parseBrewInfo(output.data, cask: cask)
            }.value
        }
    }

    private nonisolated static func process(_ command: AgentUpdateCommand, agent: String, extra: [String: String] = [:]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: agent, extra: extra)
        process.standardInput = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        return process
    }

    /// Runs a short read-only command and returns what it printed.
    private nonisolated static func capture(_ command: AgentUpdateCommand, agent: String, timeout: TimeInterval) -> (status: Int32, data: Data)? {
        let process = process(command, agent: agent, extra: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
        }
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        return (process.terminationStatus, data)
    }

    /// Runs an update, passing each line it prints; done with whether it exited cleanly and its last line.
    private nonisolated static func run(_ command: AgentUpdateCommand, agent: String,
                                        progress: @escaping @Sendable (String) -> Void) async -> (ok: Bool, last: String) {
        await Task.detached(priority: .utility) {
            let process = process(command, agent: agent)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            defer {
                try? output.fileHandleForReading.close()
                try? output.fileHandleForWriting.close()
            }
            do { try process.run() } catch { return (false, error.localizedDescription) }
            let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + updateTimeout, execute: stop)
            var last = ""
            var sent = Date.distantPast
            var buffer = Data()
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                // Installers draw progress with carriage returns: each one ends a line too.
                while let end = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                    let line = String(decoding: buffer[buffer.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    buffer.removeSubrange(buffer.startIndex...end)
                    if !line.isEmpty {
                        last = String(line.prefix(200))
                        // A few redraws a second at most, however fast the installer prints.
                        if Date().timeIntervalSince(sent) > 0.3 {
                            sent = Date()
                            progress(last)
                        }
                    }
                }
            }
            process.waitUntilExit()
            stop.cancel()
            let tail = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { last = String(tail.prefix(200)) }
            return (process.terminationStatus == 0, last)
        }.value
    }
}
