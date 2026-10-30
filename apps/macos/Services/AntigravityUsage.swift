import Foundation
import SQLite3

/// Antigravity's quota windows (per model family: 5-hour and weekly), read the way Antigravity itself does.
///
/// Antigravity's ACP server keeps its Google sign-in in `<GEMINI_HOME>/antigravity-acp/acp_token.json`:
/// first the profiles of Nook's own Antigravity sessions, then Antigravity's own folder. Nook exchanges the
/// refresh token for a short-lived access token (kept until shortly before it expires) and asks Google's Cloud Code
/// endpoint for the quota summary (`retrieveUserQuotaSummary`): the groups of Antigravity's Model Quota screen ("Gemini
/// Models", "Claude and GPT models"), each with a 5-hour and a weekly bucket. Only accounts without that summary fall back
/// to the per-model quotas of `fetchAvailableModels`. The token never leaves this
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
    /// A forced read came in while one was running: read again once that one is done.
    private var again = false
    private var lastFetch = Date.distantPast
    private static let minimumInterval: TimeInterval = 30
    /// The timer's pace at full speed.
    private static let interval: TimeInterval = 180

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledCoalesced(withTimeInterval: Self.interval) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // On battery or away, less often (`EnergyPlan.slowdown`); signing in still reads at once (`force`).
                let wait = Self.interval * EnergyMonitor.shared.plan.slowdown - 10
                guard Date().timeIntervalSince(self.lastFetch) >= wait else { return }
                self.refreshNow()
            }
        }
        refreshNow()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the windows again, at most every 30 seconds; `force` (right after signing in) reads at once.
    func refreshNow(force: Bool = false) {
        if busy {
            if force { again = true }
            return
        }
        guard force || Date().timeIntervalSince(lastFetch) >= Self.minimumInterval else { return }
        busy = true
        lastFetch = Date()
        let directories = sessionProfiles() + [home()]
        Task.detached(priority: .utility) { [weak self] in
            // A sign-in file counts as a login; a token borrowed from the Antigravity editor only when it still works.
            let hasLogin = AntigravityUsage.credentials(homes: directories, includeApp: false) != nil
            let windows = AntigravityUsage.read(homes: directories)
            await MainActor.run { [weak self] in
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
                if self.again {
                    self.again = false
                    self.refreshNow(force: true)
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

    /// The last access token per refresh token, until a minute before it expires.
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
        // Google answers only a client that calls itself Antigravity's Hub, and an old version misses newer models.
        let agent = "antigravity/hub/2.24.0 (aidev_client; os_type=darwin; arch=\(architecture); cl=1000335682)"
        let body = (try? JSONSerialization.data(withJSONObject: project.map { ["project": $0] } ?? [:])) ?? Data("{}".utf8)

        func ask(_ operation: String) -> [[String: Any]] {
            endpoints.compactMap { endpoint in
                var request = URLRequest(url: URL(string: "\(endpoint)/v1internal:\(operation)")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                return send(request) as? [String: Any]
            }
        }

        // The quota summary is what Antigravity's own Model Quota screen shows: per group of models a 5-hour and a weekly
        // window. The endpoints can report different groups (the daily one has returned Claude & GPT without Gemini):
        // every endpoint's windows count, the most used reading of a window wins.
        var summary: [Window] = []
        for answer in ask("retrieveUserQuotaSummary") { merge(summaryWindows(answer), into: &summary) }
        if !summary.isEmpty { return summary.map(\.limit) }
        // Older accounts only have a quota per model, without a window length.
        var models: [Window] = []
        for answer in ask("fetchAvailableModels") { merge(modelWindows(answer), into: &models) }
        // The model list reports every model untouched on any plan when it knows nothing; that is no reading.
        guard models.contains(where: { $0.limit.percent > 0 }) else { return nil }
        return models.map(\.limit)
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

    /// A window with the model family it belongs to, to match model quotas against the summary.
    struct Window {
        var family: String
        var limit: QuotaLimit
    }

    nonisolated static let fiveHours: TimeInterval = 5 * 3600
    nonisolated static let week: TimeInterval = 7 * 24 * 3600

    /// A window from a quota or bucket. Nil when it is switched off or says nothing about what is left.
    nonisolated static func limit(label: String, quota: [String: Any], duration: TimeInterval? = nil) -> QuotaLimit? {
        guard (quota["disabled"] as? Bool) != true else { return nil }
        let reset = resetDate(quota)
        guard let remaining = remainingFraction(quota) ?? (reset != nil ? 0.0 : nil) else { return nil }
        return QuotaLimit(label: label, percent: (1 - min(1, max(0, remaining))) * 100, resetsAt: reset, duration: duration)
    }

    /// What is left, 0...1, in each of the shapes Google sends: flat (`remainingFraction`, the CLI's `remaining_fraction`),
    /// nested (`remaining.remainingFraction`) or as a oneof (`remaining: {case, value}`). Proto3 JSON leaves a zero out,
    /// so a quota with a reset time but no fraction is used up (see `limit`).
    nonisolated static func remainingFraction(_ quota: [String: Any]) -> Double? {
        if let value = number(quota["remainingFraction"] ?? quota["remaining_fraction"]) { return value }
        guard let nested = quota["remaining"] as? [String: Any] else { return nil }
        if let value = number(nested["remainingFraction"] ?? nested["remaining_fraction"]) { return value }
        if (nested["case"] as? String) == "remainingFraction" { return number(nested["value"]) }
        return nil
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        let result = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
        return result?.isFinite == true ? result : nil
    }

    private nonisolated static func resetDate(_ quota: [String: Any]) -> Date? {
        let value = quota["resetTime"] ?? quota["reset_time"]
        if let text = value as? String { return parseDate(text) ?? Double(text).map { Date(timeIntervalSince1970: $0) } }
        return number(value).map { Date(timeIntervalSince1970: $0) }
    }

    /// Adds windows to a list; a window that is already there keeps its most used reading.
    nonisolated static func merge(_ windows: [Window], into list: inout [Window]) {
        for window in windows {
            if let index = list.firstIndex(where: { $0.limit.id == window.limit.id }) {
                if window.limit.percent > list[index].limit.percent { list[index] = window }
            } else {
                list.append(window)
            }
        }
    }

    /// The summary's windows, "Gemini · 5 hours" and "Gemini · Week" per group, the 5-hour window first as with Claude.
    /// The groups sit at the top, under `response` (the local server) or under `summary`.
    nonisolated static func summaryWindows(_ object: [String: Any]) -> [Window] {
        let root = (object["response"] as? [String: Any]) ?? (object["summary"] as? [String: Any])
            ?? ((object["command"] as? [String: Any])?["data"] as? [String: Any]) ?? object
        let groups = (root["groups"] as? [[String: Any]]) ?? []
        let sources: [(name: String, buckets: [[String: Any]])] = groups.contains(where: { !(($0["buckets"] as? [Any]) ?? []).isEmpty })
            ? groups.map { ((($0["displayName"] ?? $0["name"]) as? String) ?? "", ($0["buckets"] as? [[String: Any]]) ?? []) }
            : [("", (root["buckets"] as? [[String: Any]]) ?? [])]
        var result: [Window] = []
        for source in sources {
            var group: [(order: Int, window: Window)] = []
            for bucket in source.buckets {
                guard let id = (bucket["bucketId"] ?? bucket["id"]) as? String else { continue }
                let name = ((bucket["displayName"] ?? bucket["name"]) as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                let span = windowSpan(window: bucket["window"] as? String, id: id, name: name)
                let family = familyName(bucket: id, group: source.name)
                let kind = span == fiveHours ? tr("agents.fiveHour") : span == week ? tr("agents.week")
                    : (name.isEmpty ? tr("agents.usage.quota") : name)
                // A bucket or group of one model version ("gemini-4-argon-5h", "Gemini 4 Argon") is named after it, so
                // it stays apart from the family's own group.
                let model = modelName(id: id)
                let groupName = source.name.replacingOccurrences(of: "\\s+models?$", with: "", options: [.regularExpression, .caseInsensitive])
                    .trimmingCharacters(in: .whitespaces)
                let title = model.contains(where: \.isNumber) ? model : groupName.contains(where: \.isNumber) ? groupName : family
                guard let entry = limit(label: "\(title) · \(kind)", quota: bucket, duration: span) else { continue }
                group.append((span == fiveHours ? 0 : span == week ? 1 : 2, Window(family: family, limit: entry)))
            }
            merge(group.enumerated().sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }.map { $0.element.window }, into: &result)
        }
        return result
    }

    /// How long a bucket's window lasts: its `window` field ("5h", "weekly"), else what its id or name says.
    nonisolated static func windowSpan(window: String?, id: String, name: String) -> TimeInterval? {
        let text = [window ?? "", id, name].joined(separator: " ").lowercased()
        if window == "5h" || text.contains("5h") || text.contains("five hour") { return fiveHours }
        if window == "weekly" || text.contains("weekly") || text.contains("week") { return week }
        return nil
    }

    /// "Gemini" for the Gemini group, "Claude & GPT" for the third-party one, else the group's own name.
    private nonisolated static func familyName(bucket id: String, group: String) -> String {
        let lowered = (id + " " + group).lowercased()
        if id.hasPrefix("3p-") || lowered.contains("claude") || lowered.contains("gpt") { return "Claude & GPT" }
        if id.hasPrefix("gemini-") || lowered.contains("gemini") { return "Gemini" }
        let trimmed = group.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? id : trimmed
    }

    /// Model ids that are Antigravity's own helpers (autocomplete, chat titles, images), not models you pick.
    nonisolated static func isHelperModel(_ id: String) -> Bool {
        let id = id.lowercased()
        return id.hasPrefix("chat_") || id.hasPrefix("tab_") || ["internal", "autocomplete", "lite", "image"].contains(where: { id.contains($0) })
            || id.hasSuffix("-exp") || id.hasSuffix("-agent") || id.hasSuffix("disabled")
    }

    /// Every model's own quota, named after the model ("Gemini 4 Pro"). Only the models Antigravity lists in its picker
    /// (`agentModelSorts`) count when it sends that list; its helpers never do.
    nonisolated static func modelWindows(_ object: [String: Any]) -> [Window] {
        guard let models = object["models"] as? [String: [String: Any]] else { return [] }
        let picker = Set(((object["agentModelSorts"] as? [[String: Any]]) ?? [])
            .flatMap { ($0["groups"] as? [[String: Any]]) ?? [] }
            .flatMap { ($0["modelIds"] as? [String]) ?? [] })
        var result: [Window] = []
        for (id, model) in models.sorted(by: { $0.key < $1.key }) {
            guard (model["disabled"] as? Bool) != true, !isHelperModel(id), picker.isEmpty || picker.contains(id) else { continue }
            let provider = model["modelProvider"] as? String
            let family = provider == "MODEL_PROVIDER_GOOGLE" || id.hasPrefix("gemini-") ? "Gemini"
                : provider == "MODEL_PROVIDER_ANTHROPIC" || id.hasPrefix("claude-") ? "Claude"
                : provider == "MODEL_PROVIDER_OPENAI" || id.hasPrefix("gpt-") ? "GPT" : nil
            guard let family else { continue }
            let display = ((model["displayName"] as? String) ?? "")
                .replacingOccurrences(of: "\\s*\\([^)]*\\)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let derived = modelName(id: id)
            let name = !display.isEmpty ? display : derived.isEmpty ? family : derived
            for (key, suffix, span) in [("quotaInfo", tr("agents.usage.quota"), TimeInterval?.none), ("weeklyQuotaInfo", tr("agents.week"), Optional(week))] {
                guard let quota = model[key] as? [String: Any],
                      let entry = limit(label: "\(name) · \(suffix)", quota: quota, duration: span) else { continue }
                merge([Window(family: family, limit: entry)], into: &result)
            }
        }
        return result.sorted { $0.limit.label.localizedStandardCompare($1.limit.label) == .orderedAscending }
    }

    /// A readable model name from an id: "gemini-4-pro-high" → "Gemini 4 Pro", "claude-sonnet-4-5" → "Claude Sonnet 4.5", "3p-weekly" → "".
    nonisolated static func modelName(id: String) -> String {
        let dropped: Set<String> = ["3p", "5h", "weekly", "week", "daily", "quota", "bucket", "high", "low", "medium",
                                    "thinking", "preview", "latest", "exp", "experimental"]
        let known = ["gemini": "Gemini", "claude": "Claude", "gpt": "GPT", "oss": "OSS"]
        let words = id.lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map(String.init)
            // Long numbers are release dates ("20250514"), not versions.
            .filter { !dropped.contains($0) && !($0.count > 2 && $0.allSatisfy(\.isNumber)) }
        // "4", "5" is version 4.5.
        var parts: [String] = []
        for word in words {
            if let last = parts.last, last.allSatisfy({ $0.isNumber || $0 == "." }), word.allSatisfy(\.isNumber) {
                parts[parts.count - 1] = last + "." + word
            } else {
                parts.append(known[word] ?? (word.prefix(1).uppercased() + word.dropFirst()))
            }
        }
        return parts.joined(separator: " ")
    }

    private nonisolated static func parseDate(_ text: String) -> Date? {
        NookDates.isoFractional.date(from: text) ?? NookDates.isoPlain.date(from: text)
    }
}
