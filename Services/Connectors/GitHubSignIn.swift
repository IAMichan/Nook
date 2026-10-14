import AppKit
import Foundation
import Security

/// Koppelen met GitHub in één klik. Nook vraagt een code, zet die op je klembord, opent GitHub en wacht
/// tot jij hem daar bevestigt. Dat heet de "device flow": de app heeft geen geheim nodig en je hoeft geen
/// token met de hand te maken.
///
/// Eenmalig in te stellen door de beheerder: maak op github.com een OAuth-app aan (Settings › Developer
/// settings › OAuth Apps), zet "Enable Device Flow" aan, en vul het Client ID hieronder in. Het Client ID is
/// openbaar en geen geheim. Zolang het leeg is, toont Nook alleen het plakken van een token.
@MainActor
final class GitHubSignIn: ObservableObject {
    static let shared = GitHubSignIn()

    static let clientID = ""

    static var isAvailable: Bool { !clientID.isEmpty }

    enum Phase: Equatable {
        case idle
        /// Wacht tot jij de code bevestigt op github.com.
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
                throw NookError("GitHub gaf een ongeldig adres terug.")
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
                        throw NookError("De Keychain weigerde de koppeling. Probeer het nog eens.")
                    }
                    phase = .done
                    return
                case .pending:
                    continue
                case .slowDown:
                    interval += 5
                }
            }
            throw NookError("De code is verlopen. Probeer het nog eens.")
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
        case "access_denied": throw NookError("Je hebt de koppeling geweigerd op GitHub.")
        case "expired_token": throw NookError("De code is verlopen. Probeer het nog eens.")
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
            throw NookError("GitHub gaf een onbegrijpelijk antwoord.")
        }
        return object
    }

    private static func form(_ items: [(String, String)]) -> Data {
        var components = URLComponents()
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func message(_ json: [String: Any]) -> String {
        (json["error_description"] as? String) ?? "GitHub gaf een fout."
    }
}
