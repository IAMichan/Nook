import XCTest

/// Updating agent programs (`AgentUpdates`): who installed each from its real path, the command that updates it, and
/// reading the newest version.
final class AgentUpdateTests: XCTestCase {
    private let home = "/Users/me"

    private func owner(_ provider: RunProvider, _ path: String, exists: Set<String> = []) -> AgentInstallOwner {
        AgentUpdates.owner(of: provider, resolved: path, home: home, exists: { exists.contains($0) })
    }

    func testHomebrewOwnsCasksAndFormulae() {
        XCTAssertEqual(owner(.codex, "/opt/homebrew/Caskroom/codex/0.153.0/codex-aarch64-apple-darwin"),
                       .homebrew(brew: "/opt/homebrew/bin/brew", name: "codex", cask: true))
        // A formula built on Node keeps node_modules inside the Cellar: still Homebrew's.
        XCTAssertEqual(owner(.gemini, "/usr/local/Cellar/gemini-cli/0.20.0/libexec/lib/node_modules/@google/gemini-cli/dist/index.js"),
                       .homebrew(brew: "/usr/local/bin/brew", name: "gemini-cli", cask: false))
    }

    func testGlobalNodeInstalls() {
        let nvm = "/Users/me/.nvm/versions/node/v22.1.0"
        XCTAssertEqual(owner(.codex, nvm + "/lib/node_modules/@openai/codex/bin/codex.js", exists: [nvm + "/bin/npm"]),
                       .npm(npm: nvm + "/bin/npm", package: "@openai/codex"))
        XCTAssertEqual(owner(.opencode, "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode"),
                       .npm(npm: "npm", package: "opencode-ai"), "npm from PATH when none sits next to it")
        XCTAssertEqual(owner(.grok, "/Users/me/Library/pnpm/global/5/node_modules/@xai-official/grok/dist/cli.js"),
                       .pnpm(package: "@xai-official/grok"))
        XCTAssertEqual(owner(.gemini, "/Users/me/.bun/install/global/node_modules/@google/gemini-cli/dist/index.js"),
                       .bun(bun: "/Users/me/.bun/bin/bun", package: "@google/gemini-cli"))
        XCTAssertEqual(owner(.codex, "/Users/me/.volta/tools/image/packages/@openai/codex/lib/node_modules/@openai/codex/bin/codex.js"),
                       .volta(package: "@openai/codex"), "Volta before the npm folder inside it")
    }

    func testMise() {
        XCTAssertEqual(owner(.codex, "/Users/me/.local/share/mise/installs/npm-openai-codex/0.153.0/bin/codex"),
                       .mise(tool: "npm:@openai/codex"))
        XCTAssertEqual(owner(.opencode, "/Users/me/.local/share/mise/installs/opencode/1.0.0/bin/opencode"), .mise(tool: "opencode"))
        // npm inside a mise Node is that Node's npm.
        XCTAssertEqual(owner(.codex, "/Users/me/.local/share/mise/installs/node/22.1.0/lib/node_modules/@openai/codex/bin/codex.js"),
                       .npm(npm: "npm", package: "@openai/codex"))
    }

    func testAgentsThatUpdateThemselves() {
        XCTAssertEqual(owner(.claude, "/Users/me/.local/share/claude/versions/2.1.300"), .selfUpdate(arguments: ["update"]))
        XCTAssertEqual(owner(.claude, "/Users/me/.claude/local/node_modules/.bin/claude"), .selfUpdate(arguments: ["update"]))
        XCTAssertEqual(owner(.opencode, "/Users/me/.opencode/bin/opencode"), .selfUpdate(arguments: ["upgrade"]))
        XCTAssertEqual(owner(.cursor, "/Users/me/.local/share/cursor-agent/versions/2025.11/cursor-agent"), .selfUpdate(arguments: ["update"]))
        // Codex has no updater of its own: a binary Nook does not recognise is left to you.
        XCTAssertEqual(owner(.codex, "/Users/me/bin/codex"), .unknown)
        XCTAssertEqual(owner(.gemini, "/Applications/Some Tool.app/Contents/Resources/bin/gemini"), .app(name: "Some Tool"))
    }

    func testCommandsPerInstaller() {
        func command(_ owner: AgentInstallOwner) -> String? {
            AgentUpdates.command(for: owner, executable: "/Users/me/.local/bin/claude").map { ([$0.executable] + $0.arguments).joined(separator: " ") }
        }
        XCTAssertEqual(command(.homebrew(brew: "/opt/homebrew/bin/brew", name: "codex", cask: true)), "/opt/homebrew/bin/brew upgrade --cask codex")
        XCTAssertEqual(command(.homebrew(brew: "/opt/homebrew/bin/brew", name: "gemini-cli", cask: false)), "/opt/homebrew/bin/brew upgrade gemini-cli")
        XCTAssertEqual(command(.npm(npm: "/n/bin/npm", package: "@openai/codex")), "/n/bin/npm install -g @openai/codex@latest")
        XCTAssertEqual(command(.npm(npm: "npm", package: "opencode-ai")), "/usr/bin/env npm install -g opencode-ai@latest")
        XCTAssertEqual(command(.pnpm(package: "@xai-official/grok")), "/usr/bin/env pnpm add -g @xai-official/grok@latest")
        XCTAssertEqual(command(.bun(bun: "/b/bun", package: "x")), "/b/bun add -g x@latest")
        XCTAssertEqual(command(.volta(package: "x")), "/usr/bin/env volta install x@latest")
        XCTAssertEqual(command(.mise(tool: "npm:@openai/codex")), "/usr/bin/env mise upgrade npm:@openai/codex")
        XCTAssertEqual(command(.selfUpdate(arguments: ["update"])), "/Users/me/.local/bin/claude update")
        XCTAssertNil(command(.app(name: "Antigravity")))
        XCTAssertNil(command(.unknown))
        XCTAssertEqual(AgentUpdates.command(for: .homebrew(brew: "/opt/homebrew/bin/brew", name: "codex", cask: true), executable: "")?.display,
                       "brew upgrade --cask codex")
    }

    func testWhereTheNewestVersionComesFrom() {
        XCTAssertEqual(AgentUpdates.latestSource(for: .codex, owner: .homebrew(brew: "/b", name: "codex", cask: true)),
                       .homebrew(brew: "/b", name: "codex", cask: true))
        XCTAssertEqual(AgentUpdates.latestSource(for: .codex, owner: .pnpm(package: "@openai/codex")), .npm(package: "@openai/codex"))
        XCTAssertEqual(AgentUpdates.latestSource(for: .claude, owner: .selfUpdate(arguments: ["update"])), .npm(package: "@anthropic-ai/claude-code"))
        XCTAssertNil(AgentUpdates.latestSource(for: .cursor, owner: .selfUpdate(arguments: ["update"])), "Cursor's CLI is not on npm")
        XCTAssertFalse(AgentUpdates.updatable(.antigravity))
        XCTAssertFalse(AgentUpdates.updatable(.acp))
        XCTAssertEqual(AgentUpdates.npmDistTagsURL("@openai/codex")?.absoluteString, "https://registry.npmjs.org/-/package/@openai/codex/dist-tags")
    }

    func testParsingVersions() {
        XCTAssertEqual(AgentUpdates.parseNpmDistTags(Data(#"{"latest":"0.153.0","next":"0.154.0-alpha.1"}"#.utf8)), "0.153.0")
        XCTAssertNil(AgentUpdates.parseNpmDistTags(Data(#"{"error":"Not found"}"#.utf8)))
        let cask = #"{"formulae":[],"casks":[{"token":"codex","version":"0.153.0,abc123"}]}"#
        XCTAssertEqual(AgentUpdates.parseBrewInfo(Data(cask.utf8), cask: true), "0.153.0")
        let formula = #"{"formulae":[{"name":"gemini-cli","versions":{"stable":"0.21.1","head":"HEAD"}}],"casks":[]}"#
        XCTAssertEqual(AgentUpdates.parseBrewInfo(Data(formula.utf8), cask: false), "0.21.1")
        XCTAssertNil(AgentUpdates.parseBrewInfo(Data("not json".utf8), cask: false))
        XCTAssertTrue(AgentUpdates.isOutdated(installed: "2.1.280 (Claude Code)", latest: "2.1.300"))
        XCTAssertFalse(AgentUpdates.isOutdated(installed: "2.1.300", latest: "2.1.300"))
        XCTAssertFalse(AgentUpdates.isOutdated(installed: nil, latest: "2.1.300"), "unknown is never outdated")
    }
}
