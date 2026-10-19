import Foundation
import SQLite3

/// Antigravity's quota windows (per model family: 5-hour and weekly), read the way Antigravity itself does.
///
/// Antigravity's ACP server keeps its Google sign-in in `<GEMINI_HOME>/antigravity-acp/acp_token.json` (T3Code reads the
/// same file): first the profiles of Nook's own Antigravity sessions, then Antigravity's own folder. Nook exchanges the
/// refresh token for a short-lived access token (kept until shortly before it expires) and asks Google's Cloud Code
/// endpoint for the quota summary. The token never leaves this
/// request and is not stored or logged; nothing is written to Antigravity's files.
@MainActor
final class AntigravityUsage: ObservableObject {
    /// The windows of the account, as far as Google reports them.
    @Published private(set) var limits: [QuotaLimit] = []
    /// No sign-in file was found, so no limits can be read: the app shows a hint instead of "not available".
    @Published private(set) var noLogin = false

    /// The account directory to read, set by the app. Defaults to Antigravity's own (`~/.gemini`).
    var home: () -> URL = { AgentKind.antigravity.defaultHome }
    /// The profile folders of Nook's own Antigravity sessions (where signing in in Nook leaves its token), set by the app.
    var sessionProfiles: () -> [URL] = { [] }

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
        let directories = sessionProfiles() + [home()]
        Task.detached(priority: .utility) { [weak self] in
            // A sign-in file counts as a login; a token borrowed from the Antigravity editor only when it still works.
            let hasLogin = AntigravityUsage.credentials(homes: directories, includeApp: false) != nil
            let windows = AntigravityUsage.read(homes: directories)
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                if let windows, !windows.isEmpty {
                    if windows != self.limits { self.limits = windows }
                    self.noLogin = false
                } else {
                    // Not signed in yet, or offline: try again at the next opportunity. Old values stay until then.
                    self.lastFetch = .distantPast
                    if !hasLogin, windows == nil || windows?.isEmpty == true {
                        self.limits = []
                        self.noLogin = true
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

    /// What Antigravity's sign-in file holds. Only the refresh token is required to get a fresh access token.
    private struct Credentials {
        var clientID: String?
        var secret: String?
        var refresh: String?
        var access: String?
        var project: String?
    }

    /// Antigravity's own sign-in file, or any token file next to it (`~/.gemini` and a few folders deep), in each folder
    /// in turn; then the Antigravity editor's token.
    private nonisolated static func credentials(homes: [URL], includeApp: Bool = true) -> Credentials? {
        let fm = FileManager.default
        var urls: [URL] = []
        for home in homes {
            urls.append(home.appendingPathComponent("antigravity-acp/acp_token.json"))
            for folder in ["antigravity-acp", "antigravity", "antigravity-cli", "config"] {
                let directory = home.appendingPathComponent(folder, isDirectory: true)
                for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() where name.hasSuffix(".json") {
                    urls.append(directory.appendingPathComponent(name))
                }
            }
            urls.append(home.appendingPathComponent("oauth_creds.json"))
        }
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let file = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let credentials = Credentials(
                clientID: file["client_id"] as? String,
                secret: file["client_secret"] as? String,
                refresh: file["refresh_token"] as? String,
                access: (file["expiry_date"] as? NSNumber).map { $0.doubleValue / 1000 > Date().timeIntervalSince1970 + 60 } == true
                    ? file["access_token"] as? String : nil,
                project: file["project_id"] as? String
            )
            let canRefresh = credentials.refresh?.isEmpty == false && credentials.clientID?.isEmpty == false && credentials.secret?.isEmpty == false
            if canRefresh || credentials.access != nil { return credentials }
        }
        // The Antigravity app keeps its sign-in in its own storage; it keeps that token fresh while the app runs.
        if includeApp, let token = appToken() { return Credentials(access: token) }
        return nil
    }

    /// The access token Antigravity (the editor) stores in its global state database, if it is signed in.
    private nonisolated static func appToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key LIKE '%oauthToken%' LIMIT 1", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
        return findToken(in: String(cString: raw), depth: 0)
    }

    /// Looks for a Google access token (`ya29.…`) in a value that may be base64 wrapped, up to two layers deep.
    private nonisolated static func findToken(in text: String, depth: Int) -> String? {
        if let match = text.range(of: "ya29\\.[A-Za-z0-9_\\-\\.]+", options: .regularExpression) { return String(text[match]) }
        guard depth < 2 else { return nil }
        var normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while normalized.count % 4 != 0 { normalized += "=" }
        if let data = Data(base64Encoded: normalized) {
            let decoded = String(decoding: data, as: UTF8.self)
            if let found = findToken(in: decoded, depth: depth + 1) { return found }
            // A nested message holds its own base64 string.
            for run in decoded.split(whereSeparator: { !($0.isLetter || $0.isNumber || "+/=-_".contains($0)) }) where run.count >= 40 {
                if let found = findToken(in: String(run), depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// The last access token per refresh token, until a minute before it expires (as T3Code keeps it).
    private nonisolated(unsafe) static var tokenCache: [String: (token: String, until: Date)] = [:]
    private nonisolated static let tokenLock = NSLock()

    private nonisolated static func read(homes: [URL]) -> [QuotaLimit]? {
        guard let credentials = credentials(homes: homes) else { return nil }
        let project = credentials.project
        var access = credentials.access
        if access == nil, let clientID = credentials.clientID, let secret = credentials.secret, let refresh = credentials.refresh {
            let key = clientID + "\u{0}" + refresh
            if let cached = tokenLock.withLock({ tokenCache[key] }), cached.until > Date() {
                access = cached.token
            } else {
                var token = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
                token.httpMethod = "POST"
                token.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                token.httpBody = form(["client_id": clientID, "client_secret": secret, "refresh_token": refresh, "grant_type": "refresh_token"])
                let answer = send(token) as? [String: Any]
                access = answer?["access_token"] as? String
                if let fresh = access, let seconds = (answer?["expires_in"] as? NSNumber)?.doubleValue, seconds > 60 {
                    tokenLock.withLock { tokenCache[key] = (fresh, Date().addingTimeInterval(seconds - 60)) }
                }
            }
        }
        guard let access else { return nil }

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
