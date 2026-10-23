import Foundation

/// The model manifest at work (see ModelManifest): a fresh copy from Nook's repository, fetched through `NetworkGuard` and
/// never while you keep the model list offline, and the agents' own versions, so a model that needs a newer agent says
/// which update unlocks it. The menus are built here for the composer and the session settings alike.
extension WorkspaceManager {
    static var manifestStoreURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true).appendingPathComponent("model-manifest.json")
    }

    private static let versionRereadSeconds: TimeInterval = 30 * 60

    /// Asks the repository for a newer manifest when one is due. A copy that does not validate, or is older than the one
    /// in use, is dropped: the menus keep the last valid list.
    func refreshModelManifest() {
        let now = Date()
        guard ModelManifestRefresh.isDue(online: settings.onlineModelList, lastAttempt: manifestAttempted, now: now) else { return }
        manifestAttempted = now
        Task { [weak self] in
            guard let fetched = try? await NetworkGuard.fetch(ModelManifest.remoteURL), fetched.1.statusCode == 200,
                  let self, self.settings.onlineModelList,
                  let manifest = ModelManifest.accepting(fetched.0, over: self.modelManifest) else { return }
            ModelManifestStore(url: Self.manifestStoreURL).save(fetched.0)
            if manifest != self.modelManifest { self.modelManifest = manifest }
        }
    }

    /// Reads `--version` of the agents the manifest covers: once, and again when the program moved or after half an hour.
    func readAgentVersions(_ providers: [RunProvider]) {
        let now = Date()
        for provider in providers where modelManifest?.entry(for: provider) != nil {
            guard let path = executable(provider) else { continue }
            if let last = versionsRead[provider], last.path == path, now.timeIntervalSince(last.at) < Self.versionRereadSeconds { continue }
            versionsRead[provider] = (path, now)
            Task.detached(priority: .utility) { [weak self] in
                let version = Self.version(of: path)
                await self?.setAgentVersion(version, for: provider)
            }
        }
    }

    private func setAgentVersion(_ version: String?, for provider: RunProvider) {
        if agentVersions[provider] != version { agentVersions[provider] = version }
    }

    /// The version a program prints for `--version` ("2.1.280"), nil when it prints none within a few seconds.
    nonisolated private static func version(of path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: path, extra: [:])
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        let text = String(decoding: data.prefix(4096), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).lazy.compactMap { CLIVersion(String($0)) }.first?.description
    }

    // MARK: Menus

    /// The models to offer an agent, from what it lists itself and the manifest (see `ModelChoice.list`).
    func modelChoices(for provider: RunProvider) -> [ModelChoice] {
        ModelChoice.list(manifest: modelManifest, provider: provider, offered: agentModels[provider] ?? [],
                         installed: agentVersions[provider])
    }

    /// The menu entry `id` stands for, also under an alias ("opus").
    func modelChoice(_ id: String, for provider: RunProvider) -> ModelChoice? {
        guard !id.isEmpty else { return nil }
        let choices = modelChoices(for: provider)
        if let exact = choices.first(where: { $0.id == id }) { return exact }
        guard var alias = choices.first(where: { sameModel($0.id, id, for: provider) }) else { return nil }
        // The agent resolves an alias itself, to the newest model it knows: a saved "opus" never waits on an update.
        alias.requiredVersion = nil
        return alias
    }

    /// Whether two names stand for one model ("opus" and "claude-opus-5-5").
    func sameModel(_ a: String, _ b: String, for provider: RunProvider) -> Bool {
        if a == b { return true }
        guard !a.isEmpty, !b.isEmpty, let manifest = modelManifest else { return false }
        return manifest.canonicalID(a, for: provider) == manifest.canonicalID(b, for: provider)
    }

    /// The menu of an agent: its default, its models, the ones you typed and `extra` (the model in use, recent ones),
    /// each once even under another name, and your favorites first.
    func menuModelIDs(for provider: RunProvider, extra: [String] = []) -> [String] {
        var list = [""]
        for id in modelChoices(for: provider).map(\.id) + settings.customModels(for: provider) + extra
        where !id.isEmpty && !list.contains(where: { sameModel($0, id, for: provider) }) {
            list.append(id)
        }
        return ModelOrdering.sorted(list, favorites: settings.favoriteModels(for: provider))
    }

    /// An older model the menu leaves out until you search for it, unless it is in use or a favorite.
    func hidesLegacyModel(_ id: String, for provider: RunProvider, chosen: String) -> Bool {
        guard modelChoice(id, for: provider)?.isLegacy == true else { return false }
        return !sameModel(id, chosen, for: provider) && !settings.favoriteModels(for: provider).contains(id)
    }
}
