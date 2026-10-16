import Foundation

/// Antigravity's quota windows (per model family: 5-hour and weekly), read the way Antigravity itself does.
///
/// Antigravity (`agy`) keeps its Google sign-in in `<home>/antigravity-acp/acp_token.json`. Nook exchanges the refresh token
/// for a short-lived access token and asks Google's Cloud Code endpoint for the quota summary. The token never leaves this
/// request and is not stored or logged; nothing is written to Antigravity's files.
@MainActor
final class AntigravityUsage: ObservableObject {
    /// The windows of the account, as far as Google reports them.
    @Published private(set) var limits: [QuotaLimit] = []

    /// The account directory to read, set by the app. Defaults to Antigravity's own (`~/.gemini`).
    var home: () -> URL = { AgentKind.antigravity.defaultHome }

    private var timer: Timer?
    private var busy = false
    private var lastFetch = Date.distantPast
    private static let minimumInterval: TimeInterval = 30

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        refreshNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refreshNow() {
        guard !busy, Date().timeIntervalSince(lastFetch) >= Self.minimumInterval else { return }
        busy = true
        lastFetch = Date()
        let directory = home()
        Task.detached(priority: .utility) { [weak self] in
            let windows = AntigravityUsage.read(home: directory)
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                if let windows, !windows.isEmpty {
                    if windows != self.limits { self.limits = windows }
                } else {
                    // Not signed in yet, or offline: try again at the next opportunity. Old values stay until then.
                    self.lastFetch = .distantPast
                    if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("antigravity-acp/acp_token.json").path) {
                        self.limits = []
                    }
                }
            }
        }
    }

    // MARK: Background work

    private nonisolated static let endpoints = [
        "https://daily-cloudcode-pa.googleapis.com",
        "https://cloudcode-pa.googleapis.com",
    ]

    private nonisolated static func read(home: URL) -> [QuotaLimit]? {
        let tokenURL = home.appendingPathComponent("antigravity-acp/acp_token.json")
        guard let data = try? Data(contentsOf: tokenURL),
              let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clientID = file["client_id"] as? String, !clientID.isEmpty,
              let secret = file["client_secret"] as? String, !secret.isEmpty,
              let refresh = file["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        let project = file["project_id"] as? String

        var token = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        token.httpMethod = "POST"
        token.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        token.httpBody = form(["client_id": clientID, "client_secret": secret, "refresh_token": refresh, "grant_type": "refresh_token"])
        guard let refreshed = send(token) as? [String: Any], let access = refreshed["access_token"] as? String else { return nil }

        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        let agent = "antigravity/hub/1.0.0 (aidev_client; os_type=darwin; arch=\(architecture); cl=963137146)"
        let body = (try? JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])) ?? Data("{}".utf8)

        for operation in ["retrieveUserQuotaSummary", "fetchAvailableModels"] {
            for endpoint in endpoints {
                var request = URLRequest(url: URL(string: "\(endpoint)/v1internal:\(operation)")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                guard let object = send(request) as? [String: Any] else { continue }
                let windows = operation == "retrieveUserQuotaSummary" ? summaryWindows(object) : modelWindows(object)
                if !windows.isEmpty { return windows }
            }
        }
        return nil
    }

    private nonisolated static func form(_ values: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return Data(values.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    /// One synchronous request (this runs off the main thread). Returns the JSON body of a 200 answer.
    private nonisolated static func send(_ request: URLRequest) -> Any? {
        var request = request
        request.timeoutInterval = 10
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        URLSession.shared.dataTask(with: request) { data, response, _ in
            payload = data
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 15) == .success, status == 200, let payload else { return nil }
        return try? JSONSerialization.jsonObject(with: payload)
    }

    // MARK: Parsing

    private nonisolated static func limit(label: String, quota: [String: Any]) -> QuotaLimit? {
        guard let remaining = (quota["remainingFraction"] as? NSNumber)?.doubleValue, remaining.isFinite else { return nil }
        let reset = (quota["resetTime"] as? String).flatMap(parseDate)
        return QuotaLimit(label: label, percent: (1 - min(1, max(0, remaining))) * 100, resetsAt: reset)
    }

    private nonisolated static func summaryWindows(_ summary: [String: Any]) -> [QuotaLimit] {
        let groups = (summary["groups"] as? [[String: Any]]) ?? []
        let sources: [(name: String, buckets: [[String: Any]])] = groups.contains(where: { !(($0["buckets"] as? [Any]) ?? []).isEmpty })
            ? groups.map { (($0["displayName"] as? String) ?? "", ($0["buckets"] as? [[String: Any]]) ?? []) }
            : [("", (summary["buckets"] as? [[String: Any]]) ?? [])]
        var result: [QuotaLimit] = []
        for source in sources {
            for bucket in source.buckets {
                guard (bucket["disabled"] as? Bool) != true, let id = bucket["bucketId"] as? String else { continue }
                let trimmedGroup = source.name.trimmingCharacters(in: .whitespaces)
                let family = id.hasPrefix("gemini-") ? "Gemini" : id.hasPrefix("3p-") ? "Claude & GPT" : (trimmedGroup.isEmpty ? id : trimmedGroup)
                let window = bucket["window"] as? String
                let name = (bucket["displayName"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let kind = window == "weekly" ? tr("agents.week") : window == "5h" ? tr("agents.fiveHour") : (name.isEmpty ? "Quota" : name)
                if let entry = limit(label: "\(family) · \(kind)", quota: bucket) { result.removeAll { $0.id == entry.id }; result.append(entry) }
            }
        }
        return result
    }

    /// Older accounts only list model quotas without a window length.
    private nonisolated static func modelWindows(_ object: [String: Any]) -> [QuotaLimit] {
        guard let models = object["models"] as? [String: [String: Any]] else { return [] }
        var best: [String: QuotaLimit] = [:]
        for (id, model) in models {
            let provider = model["modelProvider"] as? String
            let family = provider == "MODEL_PROVIDER_GOOGLE" || id.hasPrefix("gemini-") ? "Gemini"
                : provider == "MODEL_PROVIDER_ANTHROPIC" || id.hasPrefix("claude-") ? "Claude"
                : provider == "MODEL_PROVIDER_OPENAI" || id.hasPrefix("gpt-") ? "GPT" : nil
            guard let family else { continue }
            for (key, suffix) in [("quotaInfo", "Quota"), ("weeklyQuotaInfo", tr("agents.week"))] {
                guard let quota = model[key] as? [String: Any],
                      let entry = limit(label: "\(family) · \(suffix)", quota: quota) else { continue }
                if best[entry.id].map({ entry.percent > $0.percent }) ?? true { best[entry.id] = entry }
            }
        }
        return best.values.sorted { $0.label < $1.label }
    }

    private nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
