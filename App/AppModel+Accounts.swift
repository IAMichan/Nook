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

        let hasProgram = history.executables[kind] != nil
        // An account that signs in with a key it already holds needs no Terminal login.
        let loggedIn = history.profileAccounts[profile.id] != nil
            || (profile.usesAPIKey && (profile.kind != .claude || profiles.hasAPIKey(profile)))
        guard !hasProgram || !loggedIn else {
            finishConnect(profile)
            return
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
