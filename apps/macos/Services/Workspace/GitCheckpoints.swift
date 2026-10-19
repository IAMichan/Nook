import Foundation

/// A snapshot of a session's files after a turn: a commit under a hidden ref, so the branch, HEAD
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
        let gone = current.subtracting(target).filter { !$0.split(separator: "/").contains("..") && !$0.hasPrefix("/") }.sorted()
        if let remote, !gone.isEmpty {
            // On the other machine: the same files removed there, a batch at a time.
            for start in stride(from: 0, to: gone.count, by: 200) {
                let batch = Array(gone[start..<min(start + 200, gone.count)])
                _ = try? ProcessRunner.run(RemoteLaunch.ssh, RemoteLaunch.run("rm", ["-f", "--"] + batch, target: remote, directory: directory),
                                           environment: ProcessInfo.processInfo.environment, timeout: 120)
            }
            return
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        for path in gone {
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
        if let remote {
            // The index lives where git runs: on the other machine.
            let index = "/tmp/nook-index-\(UUID().uuidString)"
            defer {
                _ = try? ProcessRunner.run(RemoteLaunch.ssh, RemoteLaunch.run("rm", ["-f", "--", index], target: remote, directory: nil),
                                           environment: ProcessInfo.processInfo.environment, timeout: 30)
            }
            return try body(["GIT_INDEX_FILE": index])
        }
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
        let output: ProcessRunner.Output
        if let remote {
            var variables = extra
            for key in ["GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"] { variables[key] = env[key] }
            output = try ProcessRunner.run(RemoteLaunch.ssh, RemoteLaunch.git(["-C", directory] + arguments, target: remote, directory: directory,
                                                                               environment: variables),
                                           environment: ProcessInfo.processInfo.environment, timeout: 120)
        } else {
            output = try ProcessRunner.run(executable, ["-C", directory] + arguments, in: directory, environment: env, timeout: 120)
        }
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
