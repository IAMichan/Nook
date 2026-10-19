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
