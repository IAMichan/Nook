import Foundation

/// Standard paths on disk. Everything is stored in the user's home directory.
enum NookPaths {
    static var supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Nook", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Also for folders created by older versions or another tool: only the user may enter (the hook socket relies on it).
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    /// Empty working folder for the Claude Code brain, outside the support folder, so it never sees Nook's own data.
    static var brainScratchDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nook-brain", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var socketURL: URL { supportDirectory.appendingPathComponent("hub.sock") }
    static var hookScriptURL: URL { supportDirectory.appendingPathComponent("nook-hook.sh") }
    /// Symlink to the hook script at a path without spaces (~/.nook/nook-hook), for agents that do not parse quoted commands.
    static var spaceFreeHookURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/nook-hook")
    }
    /// The workspace bridge: the socket agents' MCP server talks to, and the server script itself (see WorkspaceBridgeScript).
    static var bridgeSocketURL: URL { supportDirectory.appendingPathComponent("bridge.sock") }
    static var bridgeScriptURL: URL { supportDirectory.appendingPathComponent("nook-mcp") }
    /// Symlink to the bridge script without spaces (~/.nook/nook-mcp), for commands typed in a shell.
    static var spaceFreeBridgeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/nook-mcp")
    }
    static var databaseURL: URL { supportDirectory.appendingPathComponent("nook.sqlite") }
}
