import Foundation

/// A snapshot of a session's files after a turn (T3Code's checkpoints): a commit under a hidden ref, so the branch, HEAD
/// and the index never change.
struct RunCheckpoint: Codable, Equatable, Sendable {
    var ref: String
    var date: Date
}

/// Checkpoints are made with a temporary index (`read-tree HEAD`, `add -A`, `write-tree`, `commit-tree`, `update-ref`):
/// tracked and untracked files, not ignored ones. Restoring writes the snapshot's files back and removes files that
/// were added since. Synchronous, like the rest of GitService: call off the main thread.
extension GitService {
    static func checkpointRef(session: UUID, index: Int) -> String {
        "refs/nook/checkpoints/\(session.uuidString.lowercased())/\(index)"
    }

    /// Captures `directory` (a repository or worktree root) under `ref`. Returns the commit.
    @discardableResult
    func checkpoint(_ directory: String, ref: String) throws -> String {
        try withTemporaryIndex(directory) { env in
            let head = try? git(["rev-parse", "--verify", "-q", "HEAD"], in: directory, env: env).trimmed
            if let head, !head.isEmpty { try git(["read-tree", head], in: directory, env: env) }
            try git(["add", "-A", "--", "."], in: directory, env: env)
            let tree = try git(["write-tree"], in: directory, env: env).trimmed
            var arguments = ["commit-tree", tree, "-m", "Nook checkpoint"]
            if let head, !head.isEmpty { arguments += ["-p", head] }
            let commit = try git(arguments, in: directory, env: env).trimmed
            try git(["update-ref", ref, commit], in: directory, env: env)
            return commit
        }
    }

    /// The first snapshot of a fresh worktree: it is exactly HEAD, so the ref points there, without reading any files.
    func checkpointHead(_ directory: String, ref: String) throws {
        try git(["update-ref", ref, "HEAD"], in: directory, env: [:])
    }

    /// Puts the files of `directory` back as they were at `ref`. HEAD, the branch and the index stay as they are.
    func restore(_ directory: String, to ref: String) throws {
        let target = Set(try git(["ls-tree", "-r", "-z", "--name-only", ref], in: directory, env: [:])
            .split(separator: "\0").map(String.init))
        // What is there now (tracked and untracked, not ignored): what the snapshot does not have goes away.
        let current = try withTemporaryIndex(directory) { env -> Set<String> in
            try git(["add", "-A", "--", "."], in: directory, env: env)
            return Set(try git(["ls-files", "-z"], in: directory, env: env).split(separator: "\0").map(String.init))
        }
        try withTemporaryIndex(directory) { env in
            try git(["read-tree", ref], in: directory, env: env)
            try git(["checkout-index", "-a", "-f", "-q"], in: directory, env: env)
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for path in current.subtracting(target) where !path.contains("..") {
            let url = root.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/") else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Removes a session's checkpoints (when the session is deleted).
    func removeCheckpoints(_ directory: String, session: UUID) {
        let prefix = "refs/nook/checkpoints/\(session.uuidString.lowercased())/"
        guard let list = try? git(["for-each-ref", "--format=%(refname)", prefix], in: directory, env: [:]) else { return }
        for ref in list.split(separator: "\n") { _ = try? git(["update-ref", "-d", String(ref)], in: directory, env: [:]) }
    }

    // MARK: Helpers

    func withTemporaryIndex<T>(_ directory: String, _ body: ([String: String]) throws -> T) throws -> T {
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("nook-index-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: index) }
        return try body(["GIT_INDEX_FILE": index])
    }

    /// git with extra environment; a commit identity so `commit-tree` works without a configured user.
    @discardableResult
    func git(_ arguments: [String], in directory: String, env extra: [String: String]) throws -> String {
        var env = environment
        for (key, value) in ["GIT_AUTHOR_NAME": "Nook", "GIT_AUTHOR_EMAIL": "nook@localhost",
                             "GIT_COMMITTER_NAME": "Nook", "GIT_COMMITTER_EMAIL": "nook@localhost"] { env[key] = value }
        for (key, value) in extra { env[key] = value }
        let output = try ProcessRunner.run(executable, ["-C", directory] + arguments, in: directory, environment: env, timeout: 120)
        guard output.status == 0, !output.timedOut else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw GitError(message.isEmpty ? "git \(arguments.first ?? "") failed (\(output.status))." : message)
        }
        return output.stdout
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
