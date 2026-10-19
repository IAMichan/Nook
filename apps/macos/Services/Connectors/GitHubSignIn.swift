import AppKit
import Foundation
import Security

/// Connect to GitHub in one click. Nook requests a code, copies it to your clipboard, opens GitHub,
/// and waits for confirmation. This uses the OAuth "device flow": the app requires no secret and
/// you don't need to generate a token manually.
///
/// One-time setup by maintainer: create an OAuth app on github.com (Settings › Developer
/// settings › OAuth Apps), enable "Enable Device Flow", and fill in Client ID below. Client ID is
/// public, not a secret. While empty, Nook displays token pasting only.
@MainActor
final class GitHubSignIn: ObservableObject {
    static let shared = GitHubSignIn()

    static let clientID = ""

    static var isAvailable: Bool { !clientID.isEmpty }

    enum Phase: Equatable {
        case idle
        case checkingCLI
        /// GitHub's own login page is open (via `gh auth login --web`); Nook picks up the login once it's done.
        case waitingForCLI
        /// Waiting for code confirmation on github.com.
        case waiting(code: String, uri: URL)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?

    private struct DeviceCode {
        let deviceCode: String
        let userCode: String
        let verificationURI: String
        let expiresIn: Int
        let interval: Int
    }

    private enum Poll {
        case token(String)
        case pending
        case slowDown
    }

    /// Take over the login of the GitHub CLI (`gh auth login`): no OAuth app needed, the token comes from `gh auth token`.
    func useGitHubCLI() {
        cancel()
        phase = .checkingCLI
        task = Task {
            switch await Task.detached { Self.cliToken() }.value {
            case .success(let token): store(token)
            case .failure(let error): phase = .failed(error.message)
            }
        }
    }

    /// Repair the link without asking for a token. With an OAuth app this is the normal browser sign-in. Otherwise
    /// Nook first reuses the GitHub CLI login; when gh isn't signed in either, it opens GitHub's own login page via
    /// `gh auth login --web` and picks up the new login as soon as it's done.
    func reconnect() {
        if Self.isAvailable {
            start()
            return
        }
        cancel()
        phase = .checkingCLI
        task = Task {
            if case .success(let token) = await Task.detached({ Self.cliToken() }).value {
                store(token)
                return
            }
            guard let gh = Self.ghPath() else {
                phase = .failed(tr("connector.ghMissing"))
                return
            }
            guard Self.openCLILogin(gh) else {
                phase = .failed(tr("connector.ghNotLoggedIn"))
                return
            }
            phase = .waitingForCLI
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                if case .success(let token) = await Task.detached({ Self.cliToken() }).value {
                    store(token)
                    return
                }
            }
            phase = .failed(tr("connector.ghNotLoggedIn"))
        }
    }

    private func store(_ token: String) {
        if Keychain.write(token, account: GitHubConnector.tokenAccount) == errSecSuccess {
            phase = .done
        } else {
            phase = .failed(tr("connector.keychainDenied"))
        }
    }

    private struct CLIError: Error { let message: String }

    private nonisolated static var cliDirectories: [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(NSHomeDirectory())/.local/bin"]
    }

    private nonisolated static func ghPath() -> String? {
        cliDirectories.map { "\($0)/gh" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated static func cliToken() -> Result<String, CLIError> {
        guard let gh = ghPath() else {
            return .failure(CLIError(message: tr("connector.ghMissing")))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (cliDirectories + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["GH_PROMPT_DISABLED"] = "1"
        guard let output = try? ProcessRunner.run(gh, ["auth", "token"], environment: environment, timeout: 15),
              output.status == 0 else {
            return .failure(CLIError(message: tr("connector.ghNotLoggedIn")))
        }
        let token = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? .failure(CLIError(message: tr("connector.ghNotLoggedIn"))) : .success(token)
    }

    /// Opens Terminal with `gh auth login --web`, which sends the user to GitHub's login page in the browser.
    private static func openCLILogin(_ gh: String) -> Bool {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("nook-github-login.command")
        let quoted = "'" + gh.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let body = "#!/bin/zsh\n\(quoted) auth login --hostname github.com --git-protocol https --web && exit\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(script)
    }

    func start() {
        cancel()
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func run() async {
        do {
            let code = try await requestCode()
            guard let uri = URL(string: code.verificationURI) else {
                throw NookError("GitHub returned an invalid address.")
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code.userCode, forType: .string)
            phase = .waiting(code: code.userCode, uri: uri)
            NSWorkspace.shared.open(uri)

            var interval = max(code.interval, 5)
            let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
            while Date() < deadline {
                try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                switch try await poll(deviceCode: code.deviceCode) {
                case .token(let token):
                    guard Keychain.write(token, account: GitHubConnector.tokenAccount) == errSecSuccess else {
                        throw NookError("Keychain rejected the credentials. Please try again.")
                    }
                    phase = .done
                    return
                case .pending:
                    continue
                case .slowDown:
                    interval += 5
                }
            }
            throw NookError("The code has expired. Please try again.")
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(CloudHelp.errorText(error, service: "GitHub"))
        }
    }

    private func requestCode() async throws -> DeviceCode {
        let json = try await post("https://github.com/login/device/code", items: [
            ("client_id", Self.clientID),
            ("scope", "repo read:user")
        ])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = json["verification_uri"] as? String else {
            throw NookError(Self.message(json))
        }
        return DeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURI: uri,
            expiresIn: CloudHelp.int(json["expires_in"]) ?? 900,
            interval: CloudHelp.int(json["interval"]) ?? 5
        )
    }

    private func poll(deviceCode: String) async throws -> Poll {
        let json = try await post("https://github.com/login/oauth/access_token", items: [
            ("client_id", Self.clientID),
            ("device_code", deviceCode),
            ("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
        ])
        if let token = json["access_token"] as? String, !token.isEmpty { return .token(token) }
        switch json["error"] as? String {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown
        case "access_denied": throw NookError("You declined the authorization on GitHub.")
        case "expired_token": throw NookError("The code has expired. Please try again.")
        default: throw NookError(Self.message(json))
        }
    }

    private func post(_ urlString: String, items: [(String, String)]) async throws -> [String: Any] {
        let url = try CloudHelp.url(urlString)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Self.form(items)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await ConnectorHTTP.session.data(for: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NookError("GitHub returned an invalid response.")
        }
        return object
    }

    private static func form(_ items: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func message(_ json: [String: Any]) -> String {
        (json["error_description"] as? String) ?? "GitHub returned an error."
    }
}
