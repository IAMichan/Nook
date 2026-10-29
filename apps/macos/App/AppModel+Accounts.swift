import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// Agent integration and accounts.
extension AppModel {
    // MARK: Agent Integration

    /// Checks whether primary account for this agent is fully set up: binary found, authenticated, hooks enabled.
    func isFullyConnected(_ kind: AgentKind) -> Bool {
        isFullyConnected(AgentProfile.defaultProfile(kind))
    }

    func isFullyConnected(_ profile: AgentProfile) -> Bool {
        history.executables[profile.kind] != nil && history.profileAccounts[profile.id] != nil
            && profile.kind.targets.allSatisfy { AgentConfigInstaller.state(of: $0, home: profile.home.map { _ in profile.homeURL }) == .installed }
    }

    /// The accounts that are actually linked: signed in (or holding an API key). Accounts that were never connected stay out of the lists.
    var linkedProfiles: [AgentProfile] {
        profiles.all.filter { history.profileAccounts[$0.id] != nil }
    }

    /// Linked and usable on this Mac: signed in, and the agent is installed (Antigravity: a working Google sign-in or its
    /// agent API). Only these accounts appear when you start or answer a session and in the usage overviews, so the lists
    /// never offer an agent or a model of a service you did not connect.
    var connectedProfiles: [AgentProfile] {
        linkedProfiles.filter(isConnected)
    }

    func isConnected(_ profile: AgentProfile) -> Bool {
        guard history.profileAccounts[profile.id] != nil else { return false }
        switch profile.kind {
        // Google's ACP server that Nook installed counts too: linking the account signs in right away.
        case .antigravity: return !antigravityUsage.noLogin || AntigravityClient.isAvailable || AntigravityInstaller.shared.installed != nil
        default: return history.executables[profile.kind] != nil
        }
    }

    /// The agents Nook can start, limited to the connected ones.
    var connectedProviders: [RunProvider] {
        let kinds = Set(connectedProfiles.map(\.kind))
        return RunProvider.allCases.filter { kinds.contains($0.kind) }
    }

    /// The connected accounts of one agent, the preferred one first.
    func connectedProfiles(for provider: RunProvider) -> [AgentProfile] {
        let preferred = profiles.preferredProfile(provider.kind).id
        return connectedProfiles.filter { $0.kind == provider.kind }.sorted { a, b in a.id == preferred && b.id != preferred }
    }

    /// Models to offer for an agent: its default, the models the agent itself offers and the ones the model manifest
    /// knows (see WorkspaceManager+ModelManifest), the ones you typed, and the models you used with it recently; your
    /// favorites first.
    /// An ACP agent you added has its own models, by its profile; models others used with theirs are left out.
    func models(for provider: RunProvider, profileID: String? = nil) -> [String] {
        var recent: [String] = []
        for session in history.sessions where provider != .acp && session.agent == provider.kind && !session.model.isEmpty {
            if !recent.contains(session.model) { recent.append(session.model) }
            if recent.count >= 6 { break }
        }
        return workspace.menuModelIDs(for: provider, profileID: profileID, extra: recent)
    }

    /// How a model reads in a menu: the agent's own name for it ("GPT-5.1-Codex") or the manifest's ("opus" reads
    /// "Claude Opus 5.5"), "Default" for none.
    func modelName(_ model: String, for provider: RunProvider, profileID: String? = nil) -> String {
        if model.isEmpty { return tr("ws.model.default") }
        return workspace.modelChoice(model, for: provider, profileID: profileID)?.name ?? model
    }

    /// What the menu says about a model that needs a newer agent: "Needs Claude Code 2.1.300 or newer".
    func modelUpdateNote(_ model: String, for provider: RunProvider) -> String? {
        workspace.modelChoice(model, for: provider)?.requiredVersion.map { tr("compose.modelNeedsUpdate", provider.displayName, $0) }
    }

    /// The tooltip of such a model: which update unlocks it, and the version installed now.
    func modelUpdateHelp(_ model: String, for provider: RunProvider) -> String? {
        guard let required = workspace.modelChoice(model, for: provider)?.requiredVersion else { return nil }
        return tr("compose.modelUpdateHelp", provider.displayName, required, workspace.agentVersions[provider] ?? "?")
    }

    /// The family a model belongs to when the agent lists one model per thinking level (Antigravity's
    /// "Gemini 3 Pro (High)" and "(Low)"); the level is then picked with the effort control. Nil otherwise.
    func modelFamily(_ model: String, for provider: RunProvider, profileID: String? = nil) -> ModelVariants.Family? {
        guard provider.usesACP else { return nil }
        return ModelVariants.family(of: model, in: workspace.offeredModels(provider, profileID: profileID))
    }

    /// The model's name without its level when its level is picked with the effort control ("Gemini 3 Pro").
    func modelMenuName(_ model: String, for provider: RunProvider, profileID: String? = nil) -> String {
        modelFamily(model, for: provider, profileID: profileID)?.name ?? modelName(model, for: provider, profileID: profileID)
    }

    /// The models for the model menu: one entry per family of levels.
    func menuModels(for provider: RunProvider, profileID: String? = nil) -> [String] {
        let all = models(for: provider, profileID: profileID)
        guard provider.usesACP else { return all }
        return ModelVariants.collapse(all, in: workspace.offeredModels(provider, profileID: profileID))
    }

    /// The model to run when you pick `model` in the menu: keeps the level of `current` when the new family has it.
    func menuPick(_ model: String, keeping current: String, for provider: RunProvider, profileID: String? = nil) -> String {
        guard provider.usesACP else { return model }
        return ModelVariants.pick(model, keeping: current, in: workspace.offeredModels(provider, profileID: profileID))
    }

    /// Asks the connected agents which models they offer (at most every five minutes each), reads their versions, and
    /// looks for a newer model manifest when one is due.
    func refreshAgentModels() {
        workspace.refreshAgentModels(connectedProviders.compactMap { provider in
            connectedProfiles(for: provider).first.map { (provider: provider, profileID: $0.id) }
        })
        workspace.readAgentVersions(connectedProviders)
        workspace.refreshModelManifest()
    }

    /// Resolves account profile for a running session, or nil if unknown.
    func profile(for session: AgentSession) -> AgentProfile? {
        guard let kind = AgentKind(agentName: session.name) else { return nil }
        return profiles.profile(kind: kind, home: session.home)
    }

    func profile(for session: PastSession) -> AgentProfile? {
        profiles.profile(id: session.profileID) ?? profiles.profile(id: session.agent.rawValue)
    }

    func connect(_ kind: AgentKind) {
        connect(profiles.profile(id: kind.rawValue) ?? .defaultProfile(kind))
    }

    /// One-click setup: configures hooks and profile. If CLI is missing or unauthenticated, Nook
    /// opens a Terminal window to install and log in, automatically detecting completion.
    func connect(_ profile: AgentProfile) {
        let kind = profile.kind
        if agentConnect[profile.id]?.isBusy == true { return }
        agentConnect[profile.id] = .working(tr("app.connect.working"))

        let home = profile.home.map { _ in profile.homeURL }
        if home != nil { try? FileManager.default.createDirectory(at: profile.homeURL, withIntermediateDirectories: true) }
        var problems: [String] = []
        for target in kind.targets where AgentConfigInstaller.state(of: target, home: home) != .installed {
            do {
                _ = try AgentConfigInstaller.apply(AgentConfigInstaller.prepare(target, install: true, home: home))
            } catch {
                problems.append("\(target.title): \(error.localizedDescription)")
            }
        }
        if !problems.isEmpty {
            agentConnect[profile.id] = .failed(problems.joined(separator: "\n"))
            return
        }
        // The brain is never switched to an external service on the user's behalf: that is always their own choice.

        // Antigravity signs in right away, in your browser, instead of at its first session.
        if kind == .antigravity { return connectAntigravity(profile) }

        let hasProgram = history.executables[kind] != nil
        // An account that signs in with a key it already holds needs no Terminal login.
        let loggedIn = history.profileAccounts[profile.id] != nil
            || (profile.usesAPIKey && (profile.kind != .claude || profiles.hasAPIKey(profile)))
        guard !hasProgram || !loggedIn else {
            finishConnect(profile)
            return
        }
        // Installed but signed out: the agent's own browser login, without a Terminal window, where it has one.
        if hasProgram {
            agentConnect[profile.id] = nil
            if signInInBrowser(profile) { return }
            agentConnect[profile.id] = .working(tr("app.connect.working"))
        }

        let who = profile.isDefault ? kind.name : "\(kind.name) (\(profile.label))"
        var steps = ["echo " + TerminalLauncher.shellQuote(tr("app.connect.intro", who) + " " + (hasProgram
            ? tr("app.connect.loginHint")
            : tr("app.connect.installHint")))]
        if !hasProgram { steps.append(kind.installCommand) }
        steps.append(profile.commandPrefix + kind.loginCommand)
        do {
            try runVisibly(steps.joined(separator: " && "), in: FileManager.default.homeDirectoryForCurrentUser.path,
                           name: "nook-connect-\(profile.id)", title: tr("accounts.terminalTitle.login", kind.name))
        } catch {
            agentConnect[profile.id] = .failed(tr("app.connect.terminalFailed", error.localizedDescription))
            return
        }
        agentConnect[profile.id] = .waitingForLogin(hasProgram ? tr("app.connect.loginWait") : tr("app.connect.installWait"))
        waitForLogin(profile)
    }

    /// Polls periodically for up to 15 minutes to verify agent installation and login status.
    func waitForLogin(_ profile: AgentProfile) {
        Task { [weak self] in
            for _ in 0..<300 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, case .waitingForLogin? = self.agentConnect[profile.id] else { return }
                self.history.refresh(minimumInterval: 0)
                self.refreshQuotas()
                if self.history.executables[profile.kind] != nil, self.history.profileAccounts[profile.id] != nil {
                    self.finishConnect(profile)
                    return
                }
            }
            self?.agentConnect[profile.id] = .failed(tr("app.connect.noLogin"))
        }
    }

    /// Links Antigravity: Nook installs Google's ACP server when it is missing, then signs in with Google in your browser
    /// (at once when a sign-in is saved, unless `fresh`). The usage overview reads the account's limits straight after.
    func connectAntigravity(_ profile: AgentProfile, fresh: Bool = false) {
        let installer = AntigravityInstaller.shared
        guard installer.installed != nil else {
            agentConnect[profile.id] = .working(tr("app.connect.antigravityInstalling"))
            if !installer.isBusy { installer.install() }
            Task { [weak self] in
                while AntigravityInstaller.shared.isBusy { try? await Task.sleep(nanoseconds: 500_000_000) }
                guard let self else { return }
                if AntigravityInstaller.shared.installed != nil {
                    self.connectAntigravity(profile, fresh: fresh)
                } else if case .failed(let message) = AntigravityInstaller.shared.phase {
                    self.agentConnect[profile.id] = .failed(message)
                } else {
                    self.agentConnect[profile.id] = .failed(tr("ws.antigravity.notInstalled"))
                }
            }
            return
        }
        agentConnect[profile.id] = .waitingForLogin(tr("app.connect.antigravityBrowser"))
        workspace.signInAntigravity(profileID: profile.id, fresh: fresh) { [weak self] error in
            guard let self else { return }
            if let error {
                self.agentConnect[profile.id] = .failed(error)
            } else {
                self.finishConnect(profile)
            }
        }
    }

    /// Signs this account in through the agent's own browser login, without a Terminal window: the agent opens the sign-in
    /// page, waits for it, and quits. Nook then comes back to the front and runs `then`. False when the agent has no such
    /// login or is not installed, so the caller falls back to the Terminal.
    @discardableResult
    func signInInBrowser(_ profile: AgentProfile, then: (() -> Void)? = nil) -> Bool {
        guard let arguments = profile.kind.browserLoginArguments,
              let executable = history.executables[profile.kind] else { return false }
        if agentConnect[profile.id]?.isBusy == true { return true }
        agentConnect[profile.id] = .waitingForLogin(tr("app.connect.browserLogin", profile.kind.name))
        let environment = AgentCommand.environment(base: ProcessInfo.processInfo.environment, executable: executable,
                                                   extra: profile.environment)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.runBrowserLogin(executable, arguments: arguments, environment: environment)
            }.value
            guard let self else { return }
            if let failure = result {
                self.agentConnect[profile.id] = .failed(failure)
                ToastCenter.shared.error(failure)
                return
            }
            self.finishConnect(profile)
            NSApp.activate(ignoringOtherApps: true)
            then?()
        }
        return true
    }

    /// Runs a browser login to its end (at most fifteen minutes). Nil when it succeeded, else what went wrong.
    private nonisolated static func runBrowserLogin(_ executable: String, arguments: [String],
                                                    environment: [String: String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let output = Pipe()
        // No stdin: the agent cannot ask for a pasted code and waits for the browser instead.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return tr("app.connect.browserLoginFailed", error.localizedDescription) }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15 * 60, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus != 0 else { return nil }
        if process.terminationReason == .uncaughtSignal { return tr("app.connect.browserLoginTimeout") }
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return tr("app.connect.browserLoginFailed", String(last.prefix(200)))
    }

    func finishConnect(_ profile: AgentProfile) {
        let kind = profile.kind
        // Newly installed? Rescan so Claude Code is immediately available as a provider.
        if kind == .claude { ClaudeCodeBrain.resetLocation(); settings.objectWillChange.send() }
        let running = agentSessions.contains { self.profile(for: $0)?.id == profile.id }
        agentConnect[profile.id] = .done(running ? tr("app.connect.doneRestart") : tr("app.connect.done"))
        history.refresh(minimumInterval: 0)
        // Show the account's limits straight away.
        refreshQuotas()
    }

    // MARK: Accounts

    /// Adds a profile (e.g. work account) with dedicated config directory and initiates login.
    @discardableResult
    func addAccount(_ kind: AgentKind, label: String, home: URL? = nil) -> AgentProfile {
        let profile = profiles.add(kind: kind, label: label, home: home)
        refreshQuotas()
        if history.profileAccounts[profile.id] == nil || !isFullyConnected(profile) { connect(profile) }
        return profile
    }

    /// Adopts accounts already on this Mac (and those of running sessions), so their sessions show up in the list too.
    func adoptAccounts() {
        guard !demoMode else { return }
        let running = agentSessions.compactMap { session in
            AgentKind(agentName: session.name).map { (kind: $0, home: session.home) }
        }
        profiles.adoptExisting(running: running)
    }

    func removeAccount(_ profile: AgentProfile) {
        profiles.remove(profile.id)
        agentConnect[profile.id] = nil
    }

    func makeDefault(_ profile: AgentProfile) {
        profiles.setPreferred(profile)
    }

    /// Recent directories worked in with this profile, sorted newest first.
    func recentFolders(_ profile: AgentProfile, limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for session in history.sessions(for: profile) where !session.cwd.isEmpty {
            guard seen.insert(session.cwd).inserted, FileManager.default.fileExists(atPath: session.cwd) else { continue }
            result.append(session.cwd)
            if result.count == limit { break }
        }
        return result
    }
}
