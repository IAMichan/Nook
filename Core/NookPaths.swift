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
        return dir
    }()

    static var socketURL: URL { supportDirectory.appendingPathComponent("hub.sock") }
    static var hookScriptURL: URL { supportDirectory.appendingPathComponent("nook-hook.sh") }
    static var databaseURL: URL { supportDirectory.appendingPathComponent("nook.sqlite") }
}

struct NookError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
