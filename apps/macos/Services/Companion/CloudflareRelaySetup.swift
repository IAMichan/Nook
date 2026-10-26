import Foundation

/// What Nook sends to Cloudflare to set up a relay on the user's own account (`CloudflareRelayDeployer`), without a
/// command line: the relay's code that ships inside Nook (apps/relay/worker), its settings, and the address it gets.
/// Foundation only, so the request bodies are tested on Linux.
enum CloudflareRelaySetup {
    static let scriptName = "nook-relay"
    /// The relay's modules, as in apps/relay/worker; `index.js` is the entry point.
    static let modules = ["index.js", "mux.js", "room.js", "push.js"]
    static let compatibilityDate = "2025-06-01"
    static let api = "https://api.cloudflare.com/client/v4"

    /// Cloudflare's page to create an API token, with the permissions the relay needs already filled in (deploying
    /// Workers, reading the account). The user only signs in, confirms and copies the token.
    static var tokenPage: URL {
        var parts = URLComponents(string: "https://dash.cloudflare.com/profile/api-tokens")!
        parts.queryItems = [
            URLQueryItem(name: "permissionGroupKeys",
                         value: #"[{"key":"workers_scripts","type":"edit"},{"key":"account_settings","type":"read"}]"#),
            URLQueryItem(name: "name", value: "Nook relay"),
            URLQueryItem(name: "accountId", value: "*"),
            URLQueryItem(name: "zoneId", value: "all"),
        ]
        return parts.url!
    }

    /// The Worker's settings: its entry point, one Durable Object namespace for the rooms, and (the first time) the
    /// migration that creates it. Cloudflare refuses that migration once it ran, so an update goes without it.
    static func metadata(withMigration: Bool) -> Data {
        var metadata: [String: Any] = [
            "main_module": "index.js",
            "compatibility_date": compatibilityDate,
            "bindings": [["type": "durable_object_namespace", "name": "ROOMS", "class_name": "Room"]],
        ]
        if withMigration { metadata["migrations"] = ["new_tag": "v1", "new_sqlite_classes": ["Room"]] }
        return (try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])) ?? Data()
    }

    /// The upload of a Worker with ES modules: the settings as `metadata`, then one part per module.
    static func multipart(metadata: Data, modules: [(name: String, content: Data)], boundary: String) -> Data {
        var body = Data()
        func part(name: String, filename: String?, type: String, content: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            let file = filename.map { "; filename=\"\($0)\"" } ?? ""
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\(file)\r\n".utf8))
            body.append(Data("Content-Type: \(type)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part(name: "metadata", filename: nil, type: "application/json", content: metadata)
        for module in modules {
            part(name: module.name, filename: module.name, type: "application/javascript+module", content: module.content)
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    /// The relay's address on the account's workers.dev subdomain.
    static func address(subdomain: String) -> String { "https://\(scriptName).\(subdomain).workers.dev" }

    /// A workers.dev subdomain for an account that has none yet: "nook-" and six random letters and digits.
    static func newSubdomain() -> String {
        let characters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return "nook-" + String((0..<6).map { _ in characters.randomElement()! })
    }

    /// Which version of the relay's code this is, so a relay Nook set up is updated when Nook ships a new one.
    static func version(of modules: [(name: String, content: Data)]) -> String {
        var all = Data()
        for module in modules {
            all.append(Data(module.name.utf8))
            all.append(0)
            all.append(module.content)
        }
        return WebhookHex.encode(PureSHA256.hash(all).prefix(8))
    }
}
