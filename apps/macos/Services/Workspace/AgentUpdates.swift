import Foundation

// Updating a coding agent's command-line program from Settings › Agents. The program is updated by whatever installed it:
// Homebrew, a global npm/pnpm/bun/Volta install, mise, or the agent's own updater (`claude update`). Which one is read
// from where the program really lives once its symlinks are resolved, never guessed from the agent alone: running
// `npm install -g` over a Homebrew install leaves two copies, and the older one may stay first on PATH.
// Foundation only, so owner detection, commands and version parsing are tested (`AgentUpdateTests`).

/// What installed an agent's program, and so what updates it.
enum AgentInstallOwner: Equatable, Sendable {
    /// `brew` is the Homebrew that owns it ("/opt/homebrew/bin/brew"); a cask or a formula by `name`.
    case homebrew(brew: String, name: String, cask: Bool)
    /// A global npm install; `npm` is the npm of the Node that holds it (nvm, Homebrew's node), else "npm" on PATH.
    case npm(npm: String, package: String)
    case pnpm(package: String)
    case bun(bun: String, package: String)
    case volta(package: String)
    /// A mise tool ("npm:@openai/codex", "opencode").
    case mise(tool: String)
    /// The agent updates itself (`claude update`, `opencode upgrade`).
    case selfUpdate(arguments: [String])
    /// Inside an app bundle, which updates itself: the user updates the app.
    case app(name: String)
    /// Nook cannot tell; the user updates it the way they installed it.
    case unknown

    /// The installer's name as Settings shows it ("Homebrew", "npm").
    var name: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .npm: return "npm"
        case .pnpm: return "pnpm"
        case .bun: return "Bun"
        case .volta: return "Volta"
        case .mise: return "mise"
        case .selfUpdate: return "self"
        case .app(let name): return name
        case .unknown: return "?"
        }
    }
}

/// A command Nook runs to update an agent: an executable and its arguments, never a shell line.
struct AgentUpdateCommand: Equatable, Sendable {
    var executable: String
    var arguments: [String]

    /// As the confirmation shows it: "brew upgrade --cask codex".
    var display: String {
        ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
    }
}

/// Where Nook looks up an agent's newest version.
enum AgentLatestSource: Equatable, Sendable {
    /// The npm registry's `latest` tag of a package.
    case npm(package: String)
    /// `brew info --json=v2` of a formula or cask, from Homebrew's own index on this Mac.
    case homebrew(brew: String, name: String, cask: Bool)
}

enum AgentUpdates {
    /// The agents whose program Nook can update. Antigravity's ACP server is a release Nook downloads and checks itself
    /// (`AntigravityInstaller`), and an ACP agent you added runs from its registry with npx or uvx, which fetch the
    /// version they were given at each start: neither has a program of its own to update here.
    static func updatable(_ provider: RunProvider) -> Bool {
        switch provider {
        case .claude, .codex, .gemini, .opencode, .cursor, .grok, .pi: return true
        case .antigravity, .acp: return false
        }
    }

    /// The npm package an agent is published as, for its newest version (also when it updates itself).
    static func npmPackage(_ provider: RunProvider) -> String? {
        switch provider {
        case .claude: return "@anthropic-ai/claude-code"
        case .codex: return "@openai/codex"
        case .gemini: return "@google/gemini-cli"
        case .opencode: return "opencode-ai"
        case .grok: return "@xai-official/grok"
        case .pi: return "@earendil-works/pi-coding-agent"
        // Cursor's CLI is not on npm; Antigravity and ACP agents are not updated here.
        case .cursor, .antigravity, .acp: return nil
        }
    }

    /// The agent's own updater, when its own installer put it there.
    static func selfUpdateArguments(_ provider: RunProvider) -> [String]? {
        switch provider {
        case .claude: return ["update"]
        case .opencode: return ["upgrade"]
        case .cursor: return ["update"]
        case .codex, .gemini, .grok, .pi, .antigravity, .acp: return nil
        }
    }

    /// Where an agent's own installer puts it (in `resolved`, the program's real path).
    private static func ownInstall(_ provider: RunProvider, resolved: String, home: String) -> Bool {
        switch provider {
        case .claude: return resolved.hasPrefix(home + "/.local/share/claude/") || resolved.hasPrefix(home + "/.claude/local/")
        case .opencode: return resolved.hasPrefix(home + "/.opencode/")
        case .cursor: return resolved.contains("/cursor-agent/")
        case .codex, .gemini, .grok, .pi, .antigravity, .acp: return false
        }
    }

    /// What installed the program at `resolved` (its path with every symlink resolved). `exists` checks for an npm or
    /// Bun next to it.
    static func owner(of provider: RunProvider, resolved: String, home: String,
                      exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> AgentInstallOwner {
        let parts = resolved.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        func after(_ marker: String) -> String? {
            guard let index = parts.firstIndex(of: marker), index + 1 < parts.count, !parts[index + 1].isEmpty else { return nil }
            return parts[index + 1]
        }
        /// The package under the last `node_modules` ("@openai/codex", "opencode-ai").
        func package() -> String? {
            guard let index = parts.lastIndex(of: "node_modules"), index + 1 < parts.count else { return nil }
            let first = parts[index + 1]
            if first.hasPrefix("@") {
                guard index + 2 < parts.count else { return nil }
                return first + "/" + parts[index + 2]
            }
            return first.isEmpty ? nil : first
        }
        // Homebrew first: a formula built on Node keeps its own node_modules inside the Cellar.
        for (marker, cask) in [("Caskroom", true), ("Cellar", false)] {
            if let name = after(marker), let range = resolved.range(of: "/" + marker + "/") {
                let prefix = String(resolved[..<range.lowerBound])
                return .homebrew(brew: prefix + "/bin/brew", name: name, cask: cask)
            }
        }
        if resolved.contains("/.bun/install/global/node_modules/"), let package = package() {
            return .bun(bun: home + "/.bun/bin/bun", package: package)
        }
        if resolved.contains("/pnpm/global/") || resolved.contains("/Library/pnpm/"), let package = package() {
            return .pnpm(package: package)
        }
        if resolved.contains("/.volta/tools/image/packages/"), let package = package() {
            return .volta(package: package)
        }
        if let range = resolved.range(of: "/lib/node_modules/"), let package = package() {
            let npm = String(resolved[..<range.lowerBound]) + "/bin/npm"
            return .npm(npm: exists(npm) ? npm : "npm", package: package)
        }
        if let range = resolved.range(of: "/mise/installs/") {
            let tool = resolved[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            // mise names an npm-backed tool's folder "npm-openai-codex"; its tool name is "npm:@openai/codex".
            if tool.hasPrefix("npm-"), let package = npmPackage(provider) { return .mise(tool: "npm:" + package) }
            if !tool.isEmpty { return .mise(tool: tool) }
        }
        if ownInstall(provider, resolved: resolved, home: home), let arguments = selfUpdateArguments(provider) {
            return .selfUpdate(arguments: arguments)
        }
        if let range = resolved.range(of: ".app/") {
            let bundle = resolved[..<range.lowerBound].split(separator: "/").last.map(String.init) ?? provider.displayName
            return .app(name: bundle)
        }
        return .unknown
    }

    /// The command that updates the program `owner` installed; `executable` is the agent's program, for its own updater.
    /// Nil when the user updates it themselves (an app, or an install Nook does not recognise).
    static func command(for owner: AgentInstallOwner, executable: String) -> AgentUpdateCommand? {
        switch owner {
        case .homebrew(let brew, let name, let cask):
            return AgentUpdateCommand(executable: brew, arguments: ["upgrade"] + (cask ? ["--cask"] : []) + [name])
        case .npm(let npm, let package):
            return npm == "npm" ? env(["npm", "install", "-g", package + "@latest"])
                : AgentUpdateCommand(executable: npm, arguments: ["install", "-g", package + "@latest"])
        case .pnpm(let package): return env(["pnpm", "add", "-g", package + "@latest"])
        case .bun(let bun, let package): return AgentUpdateCommand(executable: bun, arguments: ["add", "-g", package + "@latest"])
        case .volta(let package): return env(["volta", "install", package + "@latest"])
        case .mise(let tool): return env(["mise", "upgrade", tool])
        case .selfUpdate(let arguments): return AgentUpdateCommand(executable: executable, arguments: arguments)
        case .app, .unknown: return nil
        }
    }

    /// A program found on PATH (which Nook extends with the usual install folders, see `AgentCommand.environment`).
    private static func env(_ words: [String]) -> AgentUpdateCommand {
        AgentUpdateCommand(executable: "/usr/bin/env", arguments: words)
    }

    /// Where the newest version is looked up: Homebrew's own index for a Homebrew install, else npm when the agent is
    /// published there. Nil when Nook has nowhere to ask (Cursor's own installer).
    static func latestSource(for provider: RunProvider, owner: AgentInstallOwner) -> AgentLatestSource? {
        if case .homebrew(let brew, let name, let cask) = owner { return .homebrew(brew: brew, name: name, cask: cask) }
        if case .npm(_, let package) = owner { return .npm(package: package) }
        if case .pnpm(let package) = owner { return .npm(package: package) }
        if case .bun(_, let package) = owner { return .npm(package: package) }
        if case .volta(let package) = owner { return .npm(package: package) }
        return npmPackage(provider).map { .npm(package: $0) }
    }

    /// The npm registry's dist-tags of a package: `{"latest": "0.153.0", ...}`.
    static func npmDistTagsURL(_ package: String) -> URL? {
        URL(string: "https://registry.npmjs.org/-/package/" + package + "/dist-tags")
    }

    static func parseNpmDistTags(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let latest = object["latest"] as? String else { return nil }
        return CLIVersion(latest)?.description
    }

    /// `brew info --json=v2 <name>`: a formula's stable version, or a cask's version ("2.1.300" of "2.1.300,abc").
    static func parseBrewInfo(_ data: Data, cask: Bool) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if cask {
            guard let entry = (object["casks"] as? [[String: Any]])?.first, let version = entry["version"] as? String else { return nil }
            return CLIVersion(String(version.prefix { $0 != "," }))?.description
        }
        guard let entry = (object["formulae"] as? [[String: Any]])?.first,
              let versions = entry["versions"] as? [String: Any], let stable = versions["stable"] as? String else { return nil }
        return CLIVersion(stable)?.description
    }

    /// Whether `latest` is newer than `installed`; false while either is unknown.
    static func isOutdated(installed: String?, latest: String?) -> Bool {
        guard let installed, let latest, let have = CLIVersion(installed), let newest = CLIVersion(latest) else { return false }
        return have < newest
    }
}
