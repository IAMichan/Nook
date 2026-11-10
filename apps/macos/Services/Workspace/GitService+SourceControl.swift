import Foundation

/// Git work behind source control: clones that fall back from SSH to HTTPS, the main checkout's fast-forward, one commit
/// by hash, and publishing a local project. Synchronous and blocking: call off the main thread.
extension GitService {
    // MARK: Clone

    /// What a clone did: where it went, and whether SSH was refused and HTTPS used instead.
    struct CloneResult: Equatable, Sendable {
        var path: String
        var usedHTTPS: Bool
    }

    /// Clones into `<parent>/<repo>`, or `<parent>/<host>/<owner>/<repo>` with `hostLayout`. An SSH address whose SSH
    /// connection is refused (no key, unknown host key) is tried once more over HTTPS. The folder must not exist yet.
    func clone(url: String, into parent: String, hostLayout: Bool) throws -> CloneResult {
        let clean = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isCloneURL(clean) else { throw GitError("Not a recognized Git URL (https://… or git@host:path).") }
        guard let target = CloneLayout.target(url: clean, parent: parent, hostLayout: hostLayout,
                                              folderName: Self.cloneFolderName(clean)) else {
            throw GitError("Could not read the host and owner of \(clean).")
        }
        guard !FileManager.default.fileExists(atPath: target) else { throw GitError("Directory \(target) already exists.") }
        let folder = URL(fileURLWithPath: target).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        // SSH asks nothing: without a usable key it fails at once instead of waiting for a passphrase nobody can type.
        let first = try cloneOnce(clean, to: target, in: folder, batchSSH: CloneLayout.isSSH(clean))
        if first.status == 0 { return CloneResult(path: target, usedHTTPS: false) }
        if let https = CloneLayout.httpsFallback(clean), CloneLayout.sshRefused(first.stderr) {
            try? FileManager.default.removeItem(atPath: target)
            let second = try cloneOnce(https, to: target, in: folder, batchSSH: false)
            if second.status == 0 { return CloneResult(path: target, usedHTTPS: true) }
            throw GitError(Self.message(second, fallback: "Clone failed."))
        }
        throw GitError(Self.message(first, fallback: "Clone failed."))
    }

    private func cloneOnce(_ url: String, to target: String, in folder: String, batchSSH: Bool) throws -> ProcessRunner.Output {
        var env = environment
        if batchSSH, env["GIT_SSH_COMMAND"] == nil { env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15" }
        return try ProcessRunner.run(executable, ["clone", "--", url, target], in: folder, environment: env, timeout: 900)
    }

    private static func message(_ output: ProcessRunner.Output, fallback: String) -> String {
        let text = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    // MARK: Auto-pull

    /// The main checkout that `path` (any folder or worktree of a repository) belongs to.
    func mainCheckout(of path: String) -> String? {
        guard let common = commonDirectory(for: path), URL(fileURLWithPath: common).lastPathComponent == ".git" else { return nil }
        return URL(fileURLWithPath: common).deletingLastPathComponent().path
    }

    /// Fetches the default branch and fast-forwards the main checkout to it when `AutoPull.decide` allows. Returns the
    /// verdict; throws only when the fast-forward itself fails (Git leaves the tree as it was).
    @discardableResult
    func autoPull(_ checkout: String, sessionWorking: Bool) throws -> AutoPull.Verdict {
        let remotes = remotes(checkout)
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first,
              let target = defaultBranch(checkout, remote: remote) else { return .skip(.noDefaultBranch) }
        // Look before fetching: a checkout on another branch costs nothing.
        let branch = currentBranch(checkout)
        guard branch == target else { return .skip(.notOnDefaultBranch) }
        _ = try? run(["fetch", "--quiet", "--no-tags", remote, "+refs/heads/\(target):refs/remotes/\(remote)/\(target)"],
                     in: checkout, timeout: 30)
        let tracking = "refs/remotes/\(remote)/\(target)"
        guard refExists(tracking, in: checkout) else { return .skip(.noDefaultBranch) }
        let facts = autoPullFacts(checkout, branch: branch, target: target, tracking: tracking, sessionWorking: sessionWorking)
        let verdict = AutoPull.decide(facts)
        guard verdict == .fastForward else { return verdict }
        // `--ff-only` never makes a merge commit, and Git refuses to overwrite a file it does not track.
        try run(["merge", "--ff-only", "--quiet", tracking], in: checkout, timeout: 120)
        return verdict
    }

    func autoPullFacts(_ checkout: String, branch: String?, target: String, tracking: String, sessionWorking: Bool) -> AutoPull.Facts {
        let dirty = ((try? run(["status", "--porcelain=v1", "--untracked-files=no"], in: checkout)) ?? "x").isEmpty == false
        let gitDir = (try? run(["rev-parse", "--absolute-git-dir"], in: checkout))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let busy = gitDir.isEmpty || AutoPull.operationMarkers.contains { FileManager.default.fileExists(atPath: gitDir + "/" + $0) }
        let counts = (try? run(["rev-list", "--left-right", "--count", "HEAD...\(tracking)"], in: checkout))
            .flatMap(AutoPull.parseCounts)
        return AutoPull.Facts(branch: branch, defaultBranch: target, dirty: dirty, operationInProgress: busy,
                              sessionWorking: sessionWorking, ahead: counts?.ahead ?? 1, behind: counts?.behind ?? 1)
    }

    // MARK: One commit

    /// One commit by any hash or name of it, for a link in an agent's answer. Nil when the folder does not have it.
    func commit(_ directory: String, named name: String) -> GitCommitSummary? {
        guard CommitReference.isHash(name) || name.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              let text = try? run(["log", "-n", "1", "--no-color", "--format=" + Self.logFormat, name + "^{commit}", "--"],
                                  in: directory, timeout: 10) else { return nil }
        return Self.parseLog(text).first
    }

    // MARK: Publish

    /// Makes a folder ready to publish: a repository with at least one commit. A new repository gets every file the
    /// folder has (Git's ignore rules apply) in one first commit. Returns the branch to push.
    func preparePublish(_ folder: String) throws -> String {
        if repositoryRoot(for: folder) == nil { try run(["init", "--quiet"], in: folder) }
        if !hasCommits(folder) {
            try run(["add", "-A"], in: folder, timeout: 120)
            try run(["commit", "--quiet", "--allow-empty", "-m", "Initial commit"], in: folder, timeout: 120)
        }
        guard let branch = currentBranch(folder) else { throw GitError("The folder is not on a branch.") }
        return branch
    }

    /// Adds `origin` and pushes the branch to it, answering git's question for a password with `token` once (it is not
    /// stored). Never forces.
    func publish(_ folder: String, remoteURL: String, branch: String, token: String?) throws {
        guard remotes(folder).isEmpty else { throw GitError("This repository already has a remote.") }
        try run(["remote", "add", "origin", remoteURL], in: folder)
        var env = environment
        var arguments = ["-C", folder]
        if let token {
            env["NOOK_PUBLISH_TOKEN"] = token
            arguments += ["-c", "credential.helper=", "-c", "credential.helper=" + RepositoryPublish.credentialHelper]
        }
        arguments += ["push", "--set-upstream", "origin", "HEAD:refs/heads/" + branch]
        let output = try ProcessRunner.run(executable, arguments, in: folder, environment: env, timeout: 600)
        guard output.status == 0, !output.timedOut else {
            // Back as it was, so publishing again starts clean; the repository on GitHub stays and is reused then.
            _ = try? run(["remote", "remove", "origin"], in: folder)
            throw GitError(Self.message(output, fallback: "git push failed."))
        }
    }
}
