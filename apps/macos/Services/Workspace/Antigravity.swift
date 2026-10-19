import Foundation

/// Antigravity over ACP: Google's `agy_acp_server` (a pinned release, checked byte for byte)
/// next to its `localharness_external`, a profile folder of its own (`GEMINI_HOME`) with file-based token storage, and
/// Google sign-in through the agent's own loopback server, opened in your browser. Foundation only, so tests can use it.
enum AntigravityRelease {
    static let version = "1.3.0"

    struct Member: Equatable, Sendable {
        var name: String
        var bytes: Int
    }

    struct Asset: Equatable, Sendable {
        var platform: String
        var url: URL
        var sha256: String
        var archiveBytes: Int
        var executable: Member
        var harness: Member
    }

    /// Pinned release versions for macOS.
    static func asset(arch: String) -> Asset? {
        switch arch {
        case "arm64":
            return Asset(platform: "darwin-arm64",
                         url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-arm64.zip")!,
                         sha256: "7cd97045f7b4fe81175a107cdf16f9c51484e3c78a5162cae415338bb6aa5b88", archiveBytes: 111_456_962,
                         executable: Member(name: "agy_acp_server.par", bytes: 278_535_456),
                         harness: Member(name: "localharness_external", bytes: 118_611_392))
        case "x86_64":
            return Asset(platform: "darwin-x64",
                         url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.3.0-darwin-x86_64.zip")!,
                         sha256: "bb23956b89984bf5d354af2c3725e6c57f0cc1b7228e77a0e91c9c2bc1d47646", archiveBytes: 117_245_544,
                         executable: Member(name: "agy_acp_server.par", bytes: 282_840_688),
                         harness: Member(name: "localharness_external", bytes: 124_175_392))
        default:
            return nil
        }
    }

    /// The asset for this Mac.
    static var current: Asset? {
        #if arch(arm64)
        return asset(arch: "arm64")
        #elseif arch(x86_64)
        return asset(arch: "x86_64")
        #else
        return nil
        #endif
    }

    /// The unpacked archive holds exactly the two pinned files, each of the pinned size.
    static func verify(_ files: [Member], asset: Asset) -> Bool {
        Set(files.map(\.name)) == [asset.executable.name, asset.harness.name]
            && files.allSatisfy { $0 == asset.executable || $0 == asset.harness }
    }
}

/// Where Nook keeps Antigravity's ACP server and profiles.
struct AntigravityPaths {
    let support: URL

    var tools: URL { support.appendingPathComponent("tools/antigravity-acp", isDirectory: true) }
    func versions(_ asset: AntigravityRelease.Asset) -> URL {
        tools.appendingPathComponent(asset.platform, isDirectory: true).appendingPathComponent("versions", isDirectory: true)
    }
    func release(_ asset: AntigravityRelease.Asset) -> URL {
        versions(asset).appendingPathComponent(asset.sha256, isDirectory: true)
    }
    func active(_ asset: AntigravityRelease.Asset) -> URL {
        tools.appendingPathComponent(asset.platform, isDirectory: true).appendingPathComponent("active.json")
    }
    /// One profile folder per Nook account, so each signs in on its own.
    func profile(_ profileID: String) -> URL {
        let safe = profileID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? String($0) : "_" }.joined()
        return support.appendingPathComponent("providers/antigravity", isDirectory: true).appendingPathComponent(safe.isEmpty ? "default" : safe, isDirectory: true)
    }
    var browserHelper: URL { support.appendingPathComponent("tools/antigravity-acp/open-sign-in.sh") }
    var temp: URL { support.appendingPathComponent("tools/antigravity-acp/tmp", isDirectory: true) }

    /// The installed server and harness, when the active release is complete.
    func installed(_ asset: AntigravityRelease.Asset? = AntigravityRelease.current,
                   fileManager: FileManager = .default) -> (executable: String, harness: String)? {
        guard let asset, let data = try? Data(contentsOf: active(asset)),
              let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let release = record["releaseId"] as? String, release == asset.sha256 else { return nil }
        let folder = self.release(asset)
        let executable = folder.appendingPathComponent(asset.executable.name).path
        let harness = folder.appendingPathComponent(asset.harness.name).path
        guard fileManager.isExecutableFile(atPath: executable), fileManager.fileExists(atPath: harness) else { return nil }
        return (executable, harness)
    }
}

enum AntigravityAcp {
    /// The line the server prints when it wants you to sign in.
    static let signInPrefix = "Open the following link to authenticate the ACP server: "
    static let authMethod = "oauth-personal"
    static let agentName = "antigravity-acp"

    /// Variables that would steer the server to another account or project: never passed on.
    static let removedEnvironment = [
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_CLOUD_PROJECT", "GOOGLE_CLOUD_LOCATION",
        "GOOGLE_CLOUD_QUOTA_PROJECT", "GOOGLE_GENAI_USE_VERTEXAI", "GCLOUD_PROJECT", "CLOUDSDK_CORE_PROJECT", "AGY_ACP_CCPA_PROJECT",
        "AGY_ACP_ENABLE_OAUTH", "GEMINI_HOME", "AGY_ACP_FORCE_FILE_STORAGE", "ANTIGRAVITY_HARNESS_PATH", "BROWSER",
        "PYTHONUNBUFFERED", "ELECTRON_RUN_AS_NODE"
    ]

    static func environment(profile: String, harness: String, browserHelper: String, temp: String) -> [String: String] {
        [
            "GEMINI_HOME": profile,
            "AGY_ACP_FORCE_FILE_STORAGE": "1",
            // Python reads BROWSER as a command line: the quoted helper, then the address.
            "BROWSER": "'" + browserHelper.replacingOccurrences(of: "'", with: "") + "' %s",
            "PYTHONUNBUFFERED": "1",
            "TMPDIR": temp,
            "ANTIGRAVITY_HARNESS_PATH": harness
        ]
    }

    /// `<GEMINI_HOME>/antigravity-acp/settings.json`: sign in with a personal Google account.
    static let profileSettings = #"{"auth":{"type":"oauth-personal"}}"#

    /// The helper the server calls as BROWSER: it opens Google's sign-in page and nothing else.
    static let browserHelperScript = """
    #!/bin/sh
    # Nook: Antigravity asks to sign in with Google. Only Google's sign-in page is opened.
    case "$1" in
      https://accounts.google.com/o/oauth2/v2/auth\\?*) exec /usr/bin/open "$1" ;;
    esac
    exit 0
    """

    /// The sign-in address in a line of the server's output, when it is a real Google sign-in page that returns to the
    /// server's own loopback port.
    static func signInURL(inLine line: String) -> URL? {
        guard let range = line.range(of: signInPrefix) else { return nil }
        return validSignInURL(String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func validSignInURL(_ text: String) -> URL? {
        guard text.count <= 16_384, !text.contains(where: \.isWhitespace),
              let components = URLComponents(string: text), components.scheme == "https", components.host == "accounts.google.com",
              components.path == "/o/oauth2/v2/auth", components.user == nil, components.password == nil, components.fragment == nil
        else { return nil }
        let items = components.queryItems ?? []
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        guard values("state").count == 1, let state = values("state").first, !state.isEmpty, state.count <= 512,
              values("response_type") == ["code"], values("redirect_uri").count == 1,
              let redirect = values("redirect_uri").first.flatMap(URLComponents.init(string:)),
              redirect.scheme == "http", redirect.host == "127.0.0.1", redirect.path == "/", let port = redirect.port, port >= 1024
        else { return nil }
        return components.url
    }

    /// The mode for the session's rights.
    static func mode(_ mode: ExecutionMode, permission: PermissionPolicy) -> String {
        if mode == .plan { return "plan" }
        switch permission {
        case .bypass: return "yolo"
        case .acceptEdits: return "auto_edit"
        case .ask: return "default"
        }
    }

    /// The `initialize` reply of a correctly installed server: Antigravity's own, with Google sign-in.
    static func looksInstalled(_ result: [String: Any]) -> Bool {
        let info = (result["agentInfo"] as? [String: Any]) ?? [:]
        let methods = (result["authMethods"] as? [[String: Any]]) ?? []
        return (info["name"] as? String) == agentName && methods.contains { ($0["id"] as? String) == authMethod }
    }
}
