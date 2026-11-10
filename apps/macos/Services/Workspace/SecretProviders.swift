import Foundation

/// Settings › Automation › Secret providers: how Nook reaches 1Password. The tokens live in Nook's keychain
/// (`SecretStore`); the Connect address is not a secret and lives in the defaults.
enum SecretProviders {
    static let serviceAccountAccount = "secrets.op.serviceAccountToken"
    static let connectTokenAccount = "secrets.op.connectToken"
    static let connectHostKey = "secrets.op.connectHost"

    static var connectHost: String {
        get { UserDefaults.standard.string(forKey: connectHostKey) ?? "" }
        set {
            let cleaned = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { UserDefaults.standard.removeObject(forKey: connectHostKey) }
            else { UserDefaults.standard.set(cleaned, forKey: connectHostKey) }
        }
    }

    /// The configuration as it is now: read each time, so a token you change applies to the next read.
    static func config() -> OnePassword.Config {
        OnePassword.Config(executable: OnePassword.locate(),
                           serviceAccountToken: SecretStore.read(serviceAccountAccount),
                           connectHost: connectHost.isEmpty ? nil : connectHost,
                           connectToken: SecretStore.read(connectTokenAccount))
    }

    /// Every value of `values` read now where it is a 1Password reference; the others as they are. The first that cannot
    /// be read stops it, naming the key (never a value).
    static func resolveAll(_ values: [String: String]) async throws -> [String: String] {
        guard values.values.contains(where: SecretReference.isReference) else { return values }
        var result: [String: String] = [:]
        for (key, value) in values {
            do {
                result[key] = try await resolve(value)
            } catch let failure as OnePassword.Failure {
                throw NookError("\(key): " + failure.message)
            }
        }
        return result
    }

    /// `value`, or the secret it refers to. The keychain is read off the main thread, and so is `op`.
    static func resolve(_ value: String) async throws -> String {
        guard SecretReference.isReference(value) else { return value }
        let config = await Task.detached(priority: .userInitiated) { config() }.value
        return try await OnePassword.resolve(value, config: config, runner: OnePassword.processRunner)
    }
}
