import Foundation

/// Sets up the companion relay on the user's own Cloudflare account with one API token, so reaching the Mac away from
/// home needs no command line (docs/COMPANION.md, "Away from home"). It uploads the relay's code that ships inside Nook
/// (Resources/worker, from apps/relay/worker), turns on its workers.dev address, and waits until the relay answers.
enum CloudflareRelayDeployer {
    enum Step: Equatable {
        case account, uploading, starting
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The relay's code as it ships inside Nook; nil in a build without it.
    static func bundledModules() -> [(name: String, content: Data)]? {
        var modules: [(name: String, content: Data)] = []
        for name in CloudflareRelaySetup.modules {
            let base = (name as NSString).deletingPathExtension
            guard let url = Bundle.main.url(forResource: base, withExtension: "js", subdirectory: "worker"),
                  let content = try? Data(contentsOf: url) else { return nil }
            modules.append((name, content))
        }
        return modules
    }

    /// Deploys (or updates) the relay; its address once it answers, and the account it is on. `account` is the account
    /// an earlier setup used: a token that can see several accounts goes on that one, never on a guess.
    static func deploy(token: String, account preferred: String? = nil,
                       progress: @escaping @MainActor (Step) -> Void) async throws -> (address: String, account: String) {
        guard let modules = bundledModules() else { throw Failure(message: tr("companion.relay.setup.noCode")) }
        let client = Client(token: token)

        await progress(.account)
        let accounts = ((try await client.call("GET", "/accounts?per_page=50")) as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let account: String
        if let preferred {
            // An update goes to the account the relay was set up on, or nowhere.
            guard accounts.contains(preferred) else { throw Failure(message: tr("companion.relay.setup.noAccount")) }
            account = preferred
        } else if accounts.count == 1 {
            account = accounts[0]
        } else if accounts.isEmpty {
            throw Failure(message: tr("companion.relay.setup.noAccount"))
        } else {
            throw Failure(message: tr("companion.relay.setup.severalAccounts"))
        }
        // The account's workers.dev subdomain; an account that never used Workers has none yet.
        var subdomain = (try? await client.call("GET", "/accounts/\(account)/workers/subdomain") as? [String: Any])?["subdomain"] as? String
        if subdomain?.isEmpty ?? true {
            let created = try await client.call("PUT", "/accounts/\(account)/workers/subdomain",
                                                json: ["subdomain": CloudflareRelaySetup.newSubdomain()])
            subdomain = (created as? [String: Any])?["subdomain"] as? String
        }
        guard let subdomain, !subdomain.isEmpty else { throw Failure(message: tr("companion.relay.setup.noSubdomain")) }

        await progress(.uploading)
        let script = "/accounts/\(account)/workers/scripts/\(CloudflareRelaySetup.scriptName)"
        do {
            _ = try await client.upload(script, metadata: CloudflareRelaySetup.metadata(withMigration: true), modules: modules)
        } catch let failure as Failure where failure.message.localizedCaseInsensitiveContains("migration") {
            // The rooms exist already: this is an update.
            _ = try await client.upload(script, metadata: CloudflareRelaySetup.metadata(withMigration: false), modules: modules)
        }
        _ = try await client.call("POST", script + "/subdomain", json: ["enabled": true, "previews_enabled": false])

        await progress(.starting)
        let address = CloudflareRelaySetup.address(subdomain: subdomain)
        // A new workers.dev address can take a little while to answer.
        for _ in 0..<40 {
            if await answers(address) { return (address, account) }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw Failure(message: tr("companion.relay.setup.noAnswer"))
    }

    /// Whether the relay at `address` answers its health check.
    static func answers(_ address: String) async -> Bool {
        guard let url = URL(string: address + "/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).hasPrefix("Nook relay")
    }

    /// Cloudflare's API with one token; answers come as `{success, errors, result}`.
    private struct Client {
        let token: String

        func call(_ method: String, _ path: String, json: [String: Any]? = nil) async throws -> Any? {
            var request = try makeRequest(method, path)
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: json)
            }
            return try await send(request)
        }

        func upload(_ path: String, metadata: Data, modules: [(name: String, content: Data)]) async throws -> Any? {
            var request = try makeRequest("PUT", path)
            let boundary = "nook-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = CloudflareRelaySetup.multipart(metadata: metadata, modules: modules, boundary: boundary)
            return try await send(request)
        }

        private func makeRequest(_ method: String, _ path: String) throws -> URLRequest {
            guard let url = URL(string: CloudflareRelaySetup.api + path) else { throw Failure(message: path) }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = 30
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        }

        private func send(_ request: URLRequest) async throws -> Any? {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 401 || status == 403 {
                throw Failure(message: tr("companion.relay.setup.badToken"))
            }
            guard body?["success"] as? Bool == true else {
                let errors = (body?["errors"] as? [[String: Any]])?.compactMap { $0["message"] as? String } ?? []
                throw Failure(message: errors.isEmpty ? "Cloudflare: HTTP \(status)" : "Cloudflare: " + errors.joined(separator: "; "))
            }
            return body?["result"]
        }
    }
}
