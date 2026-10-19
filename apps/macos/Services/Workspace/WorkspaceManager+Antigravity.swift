import AppKit
import Foundation

/// Antigravity sessions over ACP (see Antigravity.swift): the profile folder and sign-in helper before launch, and
/// Google's sign-in page in your browser when the server asks for it.
extension WorkspaceManager {
    var antigravityPaths: AntigravityPaths { AntigravityPaths(support: NookPaths.supportDirectory) }

    /// Makes the account's profile folder (private), its settings and the sign-in helper; the environment to launch with.
    func prepareAntigravity(profileID: String, executable: String) -> [String: String]? {
        let paths = antigravityPaths
        let harness = URL(fileURLWithPath: executable).deletingLastPathComponent()
            .appendingPathComponent(AntigravityRelease.current?.harness.name ?? "localharness_external").path
        let manager = FileManager.default
        guard manager.fileExists(atPath: harness) else { return nil }
        let profile = paths.profile(profileID)
        let settings = profile.appendingPathComponent("antigravity-acp", isDirectory: true)
        do {
            try manager.createDirectory(at: settings, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: profile.path)
            try Data(AntigravityAcp.profileSettings.utf8).write(to: settings.appendingPathComponent("settings.json"), options: .atomic)
            try manager.createDirectory(at: paths.temp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(AntigravityAcp.browserHelperScript.utf8).write(to: paths.browserHelper, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.browserHelper.path)
        } catch {
            return nil
        }
        return AntigravityAcp.environment(profile: profile.path, harness: harness, browserHelper: paths.browserHelper.path,
                                          temp: paths.temp.path)
    }

    /// The server printed its sign-in link: Google's page opens in your browser and the server's own loopback port
    /// receives the answer. Shown once per session in the timeline.
    func openAntigravitySignIn(_ id: UUID, _ url: URL) {
        guard antigravitySignIns.insert(id).inserted else { return }
        append(id, RunEvent(kind: .system, text: tr("ws.antigravity.signIn")))
        NSWorkspace.shared.open(url)
    }

    /// Signs in to Antigravity without a session, when you link the account: the server starts in the account's profile
    /// folder and `authenticate` opens Google's sign-in page in your browser (or returns at once with a saved token, unless
    /// `fresh`). The token stays in that folder, where sessions and the usage overview find it. `done` gets nil on
    /// success, otherwise the reason it failed.
    func signInAntigravity(profileID: String, fresh: Bool, done: @escaping (String?) -> Void) {
        guard let executable = AntigravityInstaller.shared.installed?.executable,
              let environment = prepareAntigravity(profileID: profileID, executable: executable) else {
            return done(tr("ws.antigravity.notInstalled"))
        }
        antigravityLogins.removeValue(forKey: profileID)?.client.stop()
        let profile = antigravityPaths.profile(profileID)
        if fresh { try? FileManager.default.removeItem(at: profile.appendingPathComponent("antigravity-acp/acp_token.json")) }
        var extra = accountEnvironment(profileID)
        extra.merge(environment) { $1 }
        var spec = LaunchSpec(executable: executable, arguments: [], extraEnvironment: extra, workingDirectory: profile.path,
                              initialInput: [], keepsInputOpen: true)
        spec.removedEnvironment = AntigravityAcp.removedEnvironment
        let client = AcpClient(spec: spec)
        client.onText = { line in
            guard let url = AntigravityAcp.signInURL(inLine: line) else { return }
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        client.onExit = { [weak self] _, stderr in
            Task { @MainActor in
                self?.finishAntigravitySignIn(profileID, client, WorkspaceManager.cleanError(stderr, status: 1))
            }
        }
        antigravityLogins[profileID] = (client, done)
        do {
            try client.start()
        } catch {
            return finishAntigravitySignIn(profileID, client, tr("ws.error.launch", error.localizedDescription))
        }
        client.request("initialize", AcpRPC.initializeParams()) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .failure(let error) = result { return self.finishAntigravitySignIn(profileID, client, error.localizedDescription) }
                client.request("authenticate", ["methodId": AntigravityAcp.authMethod]) { [weak self] result in
                    Task { @MainActor in
                        if case .failure(let error) = result {
                            self?.finishAntigravitySignIn(profileID, client, error.localizedDescription)
                        } else {
                            self?.finishAntigravitySignIn(profileID, client, nil)
                        }
                    }
                }
            }
        }
        // Signing in in the browser may take a while, but not forever.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
            self?.finishAntigravitySignIn(profileID, client, tr("app.connect.noLogin"))
        }
    }

    /// Ends a sign-in once: the server stops and the caller hears how it went.
    private func finishAntigravitySignIn(_ profileID: String, _ client: AcpClient, _ error: String?) {
        guard let login = antigravityLogins[profileID], login.client === client else { return }
        antigravityLogins[profileID] = nil
        client.onExit = nil
        client.stop()
        if error == nil { onAntigravitySignedIn?() }
        login.done(error)
    }

    /// Sets an ACP mode: as the mode config option when the agent has one, otherwise with `session/set_mode` when it
    /// lists the mode.
    func setAcpMode(_ client: AcpClient, session: String, response: [String: Any], modes: [[String: Any]], to mode: String) {
        let options = (response["configOptions"] as? [[String: Any]]) ?? []
        if let option = options.first(where: { ($0["category"] as? String) == "mode" && ($0["type"] as? String ?? "select") == "select" }),
           let configID = option["id"] as? String {
            let values = ((option["options"] as? [[String: Any]]) ?? []).flatMap { ($0["options"] as? [[String: Any]]) ?? [$0] }
            guard values.isEmpty || values.contains(where: { ($0["value"] as? String) == mode }) else { return }
            client.request("session/set_config_option", ["sessionId": session, "configId": configID, "value": mode]) { _ in }
        } else if modes.contains(where: { ($0["id"] as? String) == mode }) {
            client.request("session/set_mode", ["sessionId": session, "modeId": mode]) { _ in }
        }
    }
}
