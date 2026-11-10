import Foundation

/// A secret kept in 1Password, named by reference instead of by value: `op://vault/item/field` or
/// `op://vault/item/section/field`, optionally with `?attribute=otp`. Where Nook takes a secret (a secret for agents, an
/// MCP server's variables and headers, a secret request's field) you may give a reference; Nook reads the value with the
/// 1Password CLI (`op read`) at the moment it needs it and keeps it only in memory, never on disk.
struct SecretReference: Equatable, Sendable {
    var vault: String
    var item: String
    var section: String?
    var field: String
    var query: String?

    /// The reference as `op` takes it.
    var text: String {
        "op://" + ([vault, item] + (section.map { [$0] } ?? []) + [field]).joined(separator: "/") + (query.map { "?" + $0 } ?? "")
    }

    /// The reference in `text`, or nil when it is not one. A name may hold letters, digits, spaces, `.`, `_` and `-`
    /// (what `op` accepts); anything else, such as a quote or a `$`, makes it not a reference, so a value that only starts
    /// with `op://` is never run through a command.
    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("op://") else { return nil }
        var rest = Substring(text.dropFirst("op://".count))
        var query: String?
        if let mark = rest.firstIndex(of: "?") {
            let tail = String(rest[rest.index(after: mark)...])
            guard tail.range(of: #"^[A-Za-z]+=[A-Za-z0-9_\-]+$"#, options: .regularExpression) != nil else { return nil }
            query = tail
            rest = rest[..<mark]
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (3...4).contains(parts.count), parts.allSatisfy(Self.isValidName) else { return nil }
        vault = parts[0]
        item = parts[1]
        section = parts.count == 4 ? parts[2] : nil
        field = parts[parts.count - 1]
        self.query = query
    }

    private static func isValidName(_ part: String) -> Bool {
        !part.isEmpty && part.count <= 128 && part.first != " " && part.last != " "
            && part.allSatisfy { ($0.isLetter || $0.isNumber || " ._-".contains($0)) && !$0.isNewline }
    }

    static func isReference(_ text: String) -> Bool { SecretReference(text) != nil }
}

/// The 1Password CLI as Nook runs it: how it signs in (the desktop app, a service account, or a Connect server), and
/// reading one reference. The runner is passed in, so tests never start a process.
enum OnePassword {
    /// How long `op` may take before the secret counts as unreadable (a locked app waiting for Touch ID included).
    static let timeout: TimeInterval = 45

    /// How `op` signs in. Without a token it uses the 1Password app on this Mac (which asks you to approve).
    struct Config: Equatable, Sendable {
        var executable: String?
        var serviceAccountToken: String? = nil
        var connectHost: String? = nil
        var connectToken: String? = nil

        enum Mode: Equatable { case desktop, serviceAccount, connect }

        /// A service account wins over Connect: `op` refuses both at once.
        var mode: Mode {
            if serviceAccountToken?.isEmpty == false { return .serviceAccount }
            if connectHost?.isEmpty == false, connectToken?.isEmpty == false { return .connect }
            return .desktop
        }

        /// The variables `op` gets on top of Nook's own environment, and the ones taken away so the chosen way is the
        /// only one it sees.
        var environment: (set: [String: String], removed: [String]) {
            let all = ["OP_SERVICE_ACCOUNT_TOKEN", "OP_CONNECT_HOST", "OP_CONNECT_TOKEN"]
            switch mode {
            case .serviceAccount:
                return (["OP_SERVICE_ACCOUNT_TOKEN": serviceAccountToken ?? ""], all.filter { $0 != "OP_SERVICE_ACCOUNT_TOKEN" })
            case .connect:
                return (["OP_CONNECT_HOST": connectHost ?? "", "OP_CONNECT_TOKEN": connectToken ?? ""], ["OP_SERVICE_ACCOUNT_TOKEN"])
            case .desktop:
                return ([:], all)
            }
        }
    }

    /// The result of running `op`.
    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
    }

    /// Starts `op` and waits for it; nil when it could not start or ran out of time.
    typealias Runner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String],
                                  _ removed: [String], _ timeout: TimeInterval) async -> Output?

    enum Failure: Error, Equatable {
        case notReference
        case notInstalled
        case timedOut
        case empty
        /// `op` said no: locked, signed out, no access, or no such item. Its own first line, which never holds a value.
        case refused(String)

        /// In the user's language, for Settings.
        var localizedMessage: String {
            switch self {
            case .notReference: return tr("secrets.op.notReference")
            case .notInstalled: return tr("secrets.op.notInstalled")
            case .timedOut: return tr("secrets.op.timedOut", Int(OnePassword.timeout))
            case .empty: return tr("secrets.op.empty")
            case .refused(let reason): return tr("secrets.op.refused", reason)
            }
        }

        /// In English, for an agent's tool output and logs.
        var message: String {
            switch self {
            case .notReference: return "This is not a 1Password reference (op://vault/item/field)."
            case .notInstalled: return "The 1Password CLI (op) is not installed."
            case .timedOut: return "1Password did not answer within \(Int(OnePassword.timeout)) seconds. Unlock it and try again."
            case .empty: return "1Password returned an empty value."
            case .refused(let reason): return "1Password could not read it: \(reason)"
            }
        }
    }

    /// Where Homebrew, 1Password's installer and the usual folders put `op`.
    static let searchPaths = ["/opt/homebrew/bin/op", "/usr/local/bin/op", "/usr/bin/op"]

    static func locate(fileManager: FileManager = .default, home: String = NSHomeDirectory()) -> String? {
        (searchPaths + [home + "/.local/bin/op", home + "/bin/op"]).first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// The value behind `reference`, read now. Never logged, never kept.
    static func read(_ reference: SecretReference, config: Config, runner: Runner) async throws -> String {
        guard let executable = config.executable else { throw Failure.notInstalled }
        let environment = config.environment
        guard let output = await runner(executable, ["read", "--no-newline", reference.text], environment.set,
                                        environment.removed, timeout) else { throw Failure.timedOut }
        guard output.status == 0 else { throw Failure.refused(reason(output.stderr)) }
        let value = String(decoding: output.stdout, as: UTF8.self)
        guard !value.isEmpty else { throw Failure.empty }
        return value
    }

    /// `value` itself, or the secret it refers to when it is a reference.
    static func resolve(_ value: String, config: Config, runner: Runner) async throws -> String {
        guard let reference = SecretReference(value) else { return value }
        return try await read(reference, config: config, runner: runner)
    }

    /// Checks that `op` can sign in the configured way: `op whoami` (a Connect server cannot answer that, so it reads
    /// `probe` instead when one is given). Returns the account line `op` printed.
    static func check(config: Config, probe: SecretReference?, runner: Runner) async throws -> String {
        guard let executable = config.executable else { throw Failure.notInstalled }
        if let probe {
            _ = try await read(probe, config: config, runner: runner)
            return ""
        }
        let environment = config.environment
        guard let output = await runner(executable, ["whoami"], environment.set, environment.removed, timeout) else {
            throw Failure.timedOut
        }
        guard output.status == 0 else { throw Failure.refused(reason(output.stderr)) }
        return String(decoding: output.stdout, as: UTF8.self).components(separatedBy: .newlines)
            .first { $0.hasPrefix("Email:") || $0.hasPrefix("URL:") || $0.hasPrefix("User Type:") }?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// `op`'s error in one short line, without its "[ERROR] 2026/01/01 12:00:00" head.
    static func reason(_ stderr: String) -> String {
        let line = stderr.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        let cleaned = line.replacingOccurrences(of: #"^\[ERROR\]\s*[0-9/]+\s+[0-9:]+\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { return "op stopped without saying why." }
        return cleaned.count > 200 ? String(cleaned.prefix(200)) + "…" : cleaned
    }

    /// The runner that starts the real `op`: arguments as a list (never a shell), the value on its stdout only.
    static let processRunner: Runner = { executable, arguments, environment, removed, timeout in
        await withCheckedContinuation { (continuation: CheckedContinuation<Output?, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            var merged = ProcessInfo.processInfo.environment
            for key in removed { merged[key] = nil }
            merged.merge(environment) { _, new in new }
            process.environment = merged
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.standardInput = FileHandle.nullDevice
            let lock = NSLock()
            var finished = false
            let finish: (Output?) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                continuation.resume(returning: result)
            }
            process.terminationHandler = { done in
                let stdout = out.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                finish(Output(status: done.terminationStatus, stdout: stdout, stderr: stderr))
            }
            do {
                try process.run()
            } catch {
                return finish(nil)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
                finish(nil)
            }
        }
    }
}
