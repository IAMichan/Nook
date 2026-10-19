import Foundation
import CryptoKit

/// Reads the subscription limits of every Claude account straight from Anthropic, so they show up right after linking
/// an account instead of only once a session has run (the status line only reports while a session is open).
///
/// The login token is read from where Claude Code itself keeps it (Keychain, or `.credentials.json` in the account
/// directory); it is used only for this one read-only request and never stored or logged.
@MainActor
final class ClaudeUsage {
    private let hub: AgentHub
    private let profiles: () -> [AgentProfile]
    private var timer: Timer?
    private var lastFetch: [String: Date] = [:]
    private var busy = Set<String>()

    /// Per account at most this often; the usage endpoint is not meant for rapid polling.
    private static let minimumInterval: TimeInterval = 30

    init(hub: AgentHub, profiles: @escaping () -> [AgentProfile]) {
        self.hub = hub
        self.profiles = profiles
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledCoalesced(withTimeInterval: 180) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        refreshNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Fetches every subscription account that is not fresh yet.
    func refreshNow() {
        for profile in profiles() where profile.kind == .claude && !profile.usesAPIKey {
            fetch(profile)
        }
    }

    private func fetch(_ profile: AgentProfile) {
        let id = profile.id
        guard !busy.contains(id) else { return }
        if let last = lastFetch[id], Date().timeIntervalSince(last) < Self.minimumInterval { return }
        busy.insert(id)
        lastFetch[id] = Date()
        let home = profile.homeURL
        let isDefault = profile.isDefault
        Task.detached(priority: .utility) { [weak self] in
            let usage = ClaudeUsage.read(home: home, isDefault: isDefault)
            await MainActor.run {
                guard let self else { return }
                self.busy.remove(id)
                if let usage {
                    self.hub.applyFetchedUsage(usage, home: isDefault ? "" : AgentProfile.normalize(home.path))
                } else {
                    // Not signed in yet, or offline: try again at the next opportunity.
                    self.lastFetch[id] = nil
                }
            }
        }
    }

    // MARK: Background work

    private nonisolated static func read(home: URL, isDefault: Bool) -> PlanUsage? {
        guard let token = accessToken(home: home, isDefault: isDefault) else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 20) == .success, status == 200, let payload,
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return nil }
        let five = window(object["five_hour"])
        let week = window(object["seven_day"])
        guard five != nil || week != nil else { return nil }
        return PlanUsage(fiveHour: five, sevenDay: week, updated: Date())
    }

    private nonisolated static func window(_ raw: Any?) -> PlanWindow? {
        guard let dict = raw as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue,
              let text = dict["resets_at"] as? String, let date = parseDate(text) else { return nil }
        return PlanWindow(usedPercent: min(100, max(0, percent)), resetsAt: date)
    }

    private nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Token

    /// The OAuth access token of this account, if it is signed in with a subscription and the token is still valid.
    nonisolated static func accessToken(home: URL, isDefault: Bool) -> String? {
        var candidates: [Data] = []
        // Claude Code keeps the login in the Keychain; every extra account directory has its own entry, named after a hash of the path.
        var services = [isDefault ? "Claude Code-credentials" : "Claude Code-credentials-" + hash(home.path)]
        if !isDefault { services.append("Claude Code-credentials") }
        for service in services {
            if let data = keychainItem(service: service) { candidates.append(data) }
            if isDefault { break }
        }
        if let file = try? Data(contentsOf: home.appendingPathComponent(".credentials.json")) { candidates.append(file) }

        for data in candidates {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { continue }
            if let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue, expires / 1000 < Date().timeIntervalSince1970 { continue }
            return token
        }
        return nil
    }

    private nonisolated static func hash(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func keychainItem(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return data
    }
}
