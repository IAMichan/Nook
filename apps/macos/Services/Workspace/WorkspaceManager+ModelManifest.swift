import Foundation

/// The model manifest at work (see ModelManifest): a fresh copy from Nook's repository, fetched through `NetworkGuard` and
/// never while you keep the model list offline, and the agents' own versions, so a model that needs a newer agent says
/// which update unlocks it. The menus are built here for the composer and the session settings alike.
/// A list of model choices and what it was made from.
struct ModelChoiceMemo {
    var manifest: ModelManifest?
    var offered: [AgentModel]
    var installed: String?
    var choices: [ModelChoice]
}

extension WorkspaceManager {
    static var manifestStoreURL: URL {
        NookPaths.supportDirectory.appendingPathComponent("workspace", isDirectory: true).appendingPathComponent("model-manifest.json")
    }

    private static let versionRereadSeconds: TimeInterval = 30 * 60

    /// Asks the repository for a newer manifest when one is due (`gap` after the last attempt). A copy that does not
    /// validate, or is older than the one in use, is dropped: the menus keep the last valid list. The fetch runs in the
    /// background; a menu that is open picks up the new list when it lands.
    func refreshModelManifest(every gap: TimeInterval = ModelManifestRefresh.interval) {
        let now = Date()
        guard ModelManifestRefresh.isDue(online: settings.onlineModelList, lastAttempt: manifestAttempted, now: now, every: gap) else { return }
        manifestAttempted = now
        Task { [weak self] in
            guard let fetched = try? await NetworkGuard.fetch(ModelManifest.remoteURL), fetched.1.statusCode == 200,
                  let self, self.settings.onlineModelList,
                  let manifest = ModelManifest.accepting(fetched.0, over: self.modelManifest) else { return }
            ModelManifestStore(url: Self.manifestStoreURL).save(fetched.0)
            if manifest != self.modelManifest {
                self.modelManifest = manifest
                ModelRates.use(manifest)
            }
        }
    }

    /// Reads `--version` of the agents the manifest covers (`every`: of all of them, for Settings' update list): once,
    /// and again when the program moved or after half an hour.
    func readAgentVersions(_ providers: [RunProvider], every: Bool = false) {
        let now = Date()
        for provider in providers where every || modelManifest?.entry(for: provider) != nil {
            guard let path = executable(provider) else { continue }
            if let last = versionsRead[provider], last.path == path, now.timeIntervalSince(last.at) < Self.versionRereadSeconds { continue }
            versionsRead[provider] = (path, now)
            Task.detached(priority: .utility) { [weak self] in
                let version = Self.version(of: path)
                await self?.setAgentVersion(version, for: provider)
            }
        }
    }

    /// After an update: the version is read again and the agent asked again for its models.
    func agentWasUpdated(_ provider: RunProvider) {
        versionsRead[provider] = nil
        modelsRefreshed[Self.effortKey(provider, profileID: nil)] = nil
        readAgentVersions([provider], every: true)
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

    /// One agent's model and effort controls (see `AgentModelMenu`): an ACP agent you added by its profile.
    ///
    /// Composers ask for this in their body, which runs for every change of the workspace, so the list of models is kept
    /// until what it is made from changes: making it parses the version of every model in the manifest.
    func modelMenu(for provider: RunProvider, profileID: String? = nil) -> AgentModelMenu {
        let key = Self.effortKey(provider, profileID: profileID)
        let offered = offeredModels(provider, profileID: profileID)
        let installed = agentVersions[provider]
        var menu = AgentModelMenu(provider: provider, manifest: modelManifest, offered: offered,
                                  offeredEfforts: agentEfforts[key] ?? [], installed: installed,
                                  custom: settings.customModels(for: provider) + (profileID.map(accountModels) ?? []), favorites: settings.favoriteModels(for: provider))
        if let memo = modelChoiceMemo[key], memo.installed == installed, memo.offered == offered, memo.manifest == modelManifest {
            menu.knownChoices = memo.choices
        } else {
            let choices = menu.choices
            modelChoiceMemo[key] = ModelChoiceMemo(manifest: modelManifest, offered: offered, installed: installed, choices: choices)
            menu.knownChoices = choices
        }
        return menu
    }

    /// The models to offer an agent (see `AgentModelMenu.choices`).
    func modelChoices(for provider: RunProvider, profileID: String? = nil) -> [ModelChoice] {
        modelMenu(for: provider, profileID: profileID).choices
    }

    /// The menu entry `id` stands for, also under an alias ("opus").
    func modelChoice(_ id: String, for provider: RunProvider, profileID: String? = nil) -> ModelChoice? {
        modelMenu(for: provider, profileID: profileID).choice(id)
    }

    /// Whether two names stand for one model ("opus" and "claude-opus-5-5").
    func sameModel(_ a: String, _ b: String, for provider: RunProvider) -> Bool {
        modelMenu(for: provider).same(a, b)
    }

    /// The menu of an agent (see `AgentModelMenu.ids`).
    func menuModelIDs(for provider: RunProvider, profileID: String? = nil, extra: [String] = []) -> [String] {
        modelMenu(for: provider, profileID: profileID).ids(extra: extra)
    }

    /// An older model the menu leaves out until you search for it, unless it is in use or a favorite.
    func hidesLegacyModel(_ id: String, for provider: RunProvider, chosen: String) -> Bool {
        modelMenu(for: provider).hidesLegacy(id, chosen: chosen)
    }
}
