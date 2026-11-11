import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Fast worktrees: Nook keeps a few clean checkouts of each repository's tracked files and makes a new worktree as an
/// APFS copy-on-write clone of one of them, instead of having Git write every file again.
///
/// A new worktree is registered with `git worktree add --no-checkout`, the cached files are cloned into it
/// (`clonefile`), and the cached index is copied with each file's own stat data, so the first `git status` is fast too.
/// When the cached checkout is of an older commit, `git read-tree -m -u` moves it forward. Anything the cache cannot
/// reproduce exactly falls back to a plain `git worktree add`: a remote machine, another volume, a sparse checkout,
/// attributes with a filter (Git LFS), a SHA-256 repository, or a check that finds the worktree not clean. Only tracked
/// files are cached; `node_modules` of the main checkout comes along separately (see `cloneDependencies`).
///
/// Every function is synchronous and blocking: call off the main thread.
struct WorktreeCheckoutCache: Sendable {
    let git: GitService
    var root: URL = Self.standardRoot
    var minimumFiles = Self.standardMinimumFiles

    /// Cached checkouts kept per repository.
    static let keepPerRepository = 3
    /// A cached checkout this close to a new worktree's commit is moved forward instead of building another one.
    static let rebuildAfterChangedFiles = 500
    /// Below this many tracked files Git checks out faster than the cache's own checks take (measured: 1,900 files 0.7 s
    /// plain against 1.3 s cached; 30,000 files 2.8 s against 1.8 s), so smaller repositories are never cached.
    static let standardMinimumFiles = 5_000
    /// A repository without a new worktree for this long loses its cached checkouts.
    static let unusedRepositoryAge: TimeInterval = 30 * 24 * 60 * 60

    static var standardRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/Checkout cache", isDirectory: true)
    }

    /// Settings that change what a checkout writes; part of a cached checkout's name, so checkouts made under other
    /// settings are never used.
    static let checkoutConfig =
        #"^(core\.(autocrlf|eol|symlinks|safecrlf|checkroundtripencoding|precomposeunicode|ignorecase|filemode|attributesfile|sparsecheckout)|filter\.|lfs\.|extensions\.)"#
    /// Keeps the cache's own index in the format `GitIndexStat` reads, and never runs the repository's hooks.
    static let cacheIndexConfig = ["index.version=2", "index.skipHash=false", "core.splitIndex=false",
                                   "core.untrackedCache=false", "core.fsmonitor=false", "core.sparseCheckout=false",
                                   "core.hooksPath=/dev/null"].flatMap { ["-c", $0] }
    static let nullID = String(repeating: "0", count: 40)

    struct Entry: Equatable, Sendable {
        var directory: URL
        var tree: String
        var fingerprint: String
        var used: Date
    }

    // MARK: Pure decisions (tested)

    /// The fingerprint of a repository's checkout settings (`git config --get-regexp` output), nil when the cache cannot
    /// reproduce its checkouts: a sparse checkout or a SHA-256 repository.
    static func fingerprint(config: String) -> String? {
        let lines = config.split(whereSeparator: { $0 == "\n" || $0 == "\0" }).map(String.init).sorted()
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let key = parts.first?.lowercased() ?? ""
            let value = parts.count > 1 ? parts[1].lowercased() : "true"
            if key == "core.sparsecheckout", !["false", "no", "off", "0"].contains(value) { return nil }
            if key == "extensions.objectformat", value != "sha1" { return nil }
        }
        return String(hex(sha256(Data(lines.joined(separator: "\n").utf8))).prefix(16))
    }

    /// Whether attribute text names a filter (`filter=lfs`, `-filter`, `!filter`): its checkout output depends on
    /// something outside the repository, so such a repository is never cached.
    static func namesFilter(attributes: String) -> Bool {
        attributes.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { return false }
            return trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).dropFirst().contains { word in
                let name = word.drop(while: { $0 == "-" || $0 == "!" }).split(separator: "=").first.map(String.init)
                return name == "filter"
            }
        }
    }

    /// `<tree>-<fingerprint>`: checkouts of one tree under different settings never replace each other.
    static func parseEntryName(_ name: String) -> (tree: String, fingerprint: String)? {
        let parts = name.split(separator: "-")
        guard parts.count == 2, parts[0].count == 40, parts[1].count == 16,
              parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) }) else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// What `git diff-tree -r -z --name-status --no-renames` says changed: how many paths, and whether any attributes
    /// file is among them (`read-tree -m -u` would leave files whose attributes changed as they are).
    static func parseChanges(_ text: String) -> (count: Int, attributes: Bool) {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        var count = 0
        var attributes = false
        var index = 0
        while index + 1 < fields.count {
            let file = fields[index + 1]
            count += 1
            if file == ".gitattributes" || file.hasSuffix("/.gitattributes") { attributes = true }
            index += 2
        }
        return (count, attributes)
    }

    /// Whether the lockfiles of the main checkout and a new worktree say the same dependencies are installed.
    static func dependenciesMatch(main: [String: Data], worktree: [String: Data]) -> Bool {
        !main.isEmpty && main == worktree
    }

    /// The number of entries an index file says it has (its header), without reading the rest.
    static func indexEntryCount(_ url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              Array(header.prefix(4)) == GitIndexStat.signature else { return nil }
        return header.suffix(4).reduce(0) { $0 << 8 | Int($1) }
    }

    static let lockfiles = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"]

    // MARK: Creating a worktree

    /// Creates a worktree on a new `branch` from `base` out of a cached checkout. False: nothing was created (any partial
    /// worktree and its branch were removed again) and the caller runs `git worktree add` itself.
    func create(repo: String, path: String, branch: String, base: String) -> Bool {
        guard git.remote == nil else { return false }
        // Nothing cached for this repository (it is small, or new): no further checks, git checks out at once.
        let bucket = bucketDirectory(repo)
        let cached = entries(in: bucket)
        guard !cached.isEmpty, let fingerprint = fingerprint(repo), !usesFilter(repo: repo, ref: base),
              let target = treeOf(base, in: repo) else { return false }
        let compatible = cached.filter { $0.fingerprint == fingerprint }
        guard !compatible.isEmpty else { return false }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        // A clone only works within one volume.
        guard Self.device(bucket.path) != nil, Self.device(bucket.path) == Self.device(parent) else { return false }
        var chosen = compatible.first { $0.tree == target }
        if chosen == nil {
            for entry in compatible {
                guard let text = try? git.run(["diff-tree", "-r", "-z", "--name-status", "--no-renames", entry.tree, target],
                                              in: repo, timeout: 30) else { continue }
                let changes = Self.parseChanges(text)
                if !changes.attributes { chosen = entry; break }
            }
        }
        guard let entry = chosen else { return false }
        guard (try? git.run(["worktree", "add", "--no-checkout", "--no-track", "-b", branch, "--", path, base],
                            in: repo, timeout: 60)) != nil else { return false }
        if populate(path: path, entry: entry, target: target) {
            touch(entry.directory)
            touch(bucket)
            return true
        }
        rollback(repo: repo, path: path, branch: branch)
        return false
    }

    /// Fills a freshly registered worktree from `entry`; false on anything unexpected.
    private func populate(path: String, entry: Entry, target: String) -> Bool {
        let fm = FileManager.default
        let files = entry.directory.appendingPathComponent("files")
        guard let names = try? fm.contentsOfDirectory(atPath: files.path),
              let gitDir = gitDirectory(of: path) else { return false }
        // The worktree folder already holds Git's `.git` file, so its entries are cloned one by one.
        for name in names where name != ".git" {
            guard clonefile(files.appendingPathComponent(name).path, path + "/" + name, UInt32(CLONE_NOFOLLOW)) == 0
            else { return false }
        }
        guard let cached = try? Data(contentsOf: entry.directory.appendingPathComponent("index")) else { return false }
        let restated: Data
        do {
            restated = try GitIndexStat.restated(cached, verify: true) { GitIndexStat.lstat(root: path, path: $0) }
        } catch GitIndexStat.Problem.changed {
            // A cached file changed after Git wrote it: never hand that checkout out again.
            try? fm.removeItem(at: entry.directory)
            return false
        } catch {
            return false
        }
        guard (try? restated.write(to: URL(fileURLWithPath: gitDir + "/index"), options: .atomic)) != nil else { return false }
        if entry.tree != target {
            guard (try? git.run(["-c", "core.hooksPath=/dev/null", "read-tree", "-m", "-u", entry.tree, target],
                                in: path, timeout: 120)) != nil else { return false }
            // The files read-tree wrote are stamped in the index's own second: rewrite it once, or every status re-reads them.
            git.refreshNewWorktreeIndex(path)
        }
        // The worktree must be exactly what `git worktree add` would make: nothing changed, nothing extra.
        guard let status = try? git.run(["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all"],
                                        in: path, timeout: 60), status.isEmpty else { return false }
        return true
    }

    private func rollback(repo: String, path: String, branch: String) {
        _ = try? git.run(["worktree", "remove", "--force", "--", path], in: repo, timeout: 60)
        try? FileManager.default.removeItem(atPath: path)
        _ = try? git.run(["worktree", "prune"], in: repo)
        // The branch was made a moment ago, at `base`, by this attempt: the fallback makes it again.
        _ = try? git.run(["branch", "-D", "--", branch], in: repo)
    }

    /// Runs the `post-checkout` hook the way `git worktree add` does (`--no-checkout` skips it). Throws when it fails.
    func runPostCheckoutHook(worktree path: String) throws {
        let commit = try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        let output = try git.raw(["-C", path, "hook", "run", "--ignore-missing", "post-checkout", "--", Self.nullID, commit, "1"],
                                 in: path, timeout: 600)
        guard output.status == 0 else {
            throw GitError("The repository's post-checkout hook failed: " + output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: Filling the cache

    /// Caches the checkout of `worktree` (a worktree Git just checked out), unless a cached checkout is already close to
    /// it. Best effort; meant for a background task after a new worktree.
    func build(worktree: String, repo: String) {
        guard git.remote == nil, let fingerprint = fingerprint(repo),
              let tree = treeOf("HEAD", in: worktree), !usesFilter(repo: repo, ref: "HEAD", in: worktree) else { return }
        let fm = FileManager.default
        guard let gitDir = gitDirectory(of: worktree),
              (Self.indexEntryCount(URL(fileURLWithPath: gitDir + "/index")) ?? 0) >= minimumFiles else { return }
        let bucket = bucketDirectory(repo)
        try? fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        let compatible = entries(in: bucket).filter { $0.fingerprint == fingerprint }
        if compatible.contains(where: { $0.tree == tree }) { return }
        for entry in compatible {
            guard let text = try? git.run(["diff-tree", "-r", "-z", "--name-status", "--no-renames", entry.tree, tree],
                                          in: repo, timeout: 30) else { continue }
            let changes = Self.parseChanges(text)
            if !changes.attributes, changes.count < Self.rebuildAfterChangedFiles { return }
        }
        removeLeftovers(in: bucket)
        let staging = bucket.appendingPathComponent(".staging-" + UUID().uuidString, isDirectory: true)
        let files = staging.appendingPathComponent("files", isDirectory: true)
        let index = staging.appendingPathComponent("index")
        do {
            try fm.createDirectory(at: files, withIntermediateDirectories: true)
            var env = git.environment
            env["GIT_INDEX_FILE"] = index.path
            let output = try ProcessRunner.run(git.executable, Self.cacheIndexConfig + ["-C", repo, "--work-tree=" + files.path,
                                                                                         "read-tree", "--reset", "-u", tree],
                                               environment: env, timeout: 600)
            guard output.status == 0, !output.timedOut else { throw GitError("git read-tree failed") }
            // Record the files' own stat data; Git leaves entries it wrote in the same second for a later re-read.
            let written = try Data(contentsOf: index)
            let restated = try GitIndexStat.restated(written, verify: false) { GitIndexStat.lstat(root: files.path, path: $0) }
            try restated.write(to: index, options: .atomic)
            try fm.moveItem(at: staging, to: bucket.appendingPathComponent("\(tree)-\(fingerprint)", isDirectory: true))
        } catch {
            try? fm.removeItem(at: staging)
            return
        }
        touch(bucket)
        for old in entries(in: bucket).dropFirst(Self.keepPerRepository) { try? fm.removeItem(at: old.directory) }
        removeUnusedRepositories(except: bucket)
    }

    /// Deletes every cached checkout (fast worktrees switched off), off the main thread.
    static func clear(root: URL = standardRoot) {
        DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: root) }
    }

    /// Clones the main checkout's `node_modules` into a new worktree when its lockfile is the same, so the worktree can
    /// run right away. Copy-on-write: it takes no space until one of them changes. Best effort.
    func cloneDependencies(from main: String, to worktree: String) {
        let fm = FileManager.default
        let source = main + "/node_modules"
        let destination = worktree + "/node_modules"
        var isDirectory: ObjCBool = false
        guard git.remote == nil, fm.fileExists(atPath: source, isDirectory: &isDirectory), isDirectory.boolValue,
              !fm.fileExists(atPath: destination) else { return }
        func locks(_ folder: String) -> [String: Data] {
            var result: [String: Data] = [:]
            for name in Self.lockfiles { result[name] = fm.contents(atPath: folder + "/" + name) }
            return result
        }
        guard Self.dependenciesMatch(main: locks(main), worktree: locks(worktree)),
              Self.device(main) == Self.device(worktree),
              // Only when Git ignores it there too: a tracked node_modules is already in the checkout.
              (try? git.run(["check-ignore", "-q", "node_modules"], in: worktree)) != nil else { return }
        _ = clonefile(source, destination, UInt32(CLONE_NOFOLLOW))
    }

    // MARK: Helpers

    func fingerprint(_ repo: String) -> String? {
        let config = (try? git.run(["config", "--get-regexp", Self.checkoutConfig], in: repo, okStatuses: [0, 1])) ?? ""
        return Self.fingerprint(config: config)
    }

    /// Whether any attributes that apply to `ref`'s checkout name a filter: the repository's `.gitattributes` files, its
    /// `info/attributes`, and the user's and system attributes files.
    func usesFilter(repo: String, ref: String, in directory: String? = nil) -> Bool {
        let folder = directory ?? repo
        let attributeFiles = ((try? git.run(["ls-tree", "-r", "-z", "--name-only", ref], in: folder, timeout: 60)) ?? "")
            .split(separator: "\0").map(String.init)
            .filter { $0 == ".gitattributes" || $0.hasSuffix("/.gitattributes") }
        for file in attributeFiles {
            let text = (try? git.run(["cat-file", "blob", "\(ref):\(file)"], in: folder)) ?? ""
            if Self.namesFilter(attributes: text) { return true }
        }
        var others: [String] = []
        if let common = git.commonDirectory(for: folder) { others.append(common + "/info/attributes") }
        let configured = (try? git.run(["config", "--path", "core.attributesFile"], in: folder, okStatuses: [0, 1]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty { others.append(configured) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? home + "/.config"
        others += [xdg + "/git/attributes", "/etc/gitattributes", "/opt/homebrew/etc/gitattributes", "/usr/local/etc/gitattributes"]
        return others.contains { (try? String(contentsOfFile: $0, encoding: .utf8)).map(Self.namesFilter) ?? false }
    }

    func treeOf(_ ref: String, in directory: String) -> String? {
        let text = (try? git.run(["rev-parse", "--verify", "--quiet", ref + "^{tree}"], in: directory))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.count == 40 ? text : nil
    }

    /// One folder per repository, named after its shared `.git` directory.
    func bucketDirectory(_ repo: String) -> URL {
        let common = git.commonDirectory(for: repo) ?? repo
        let key = Self.hex(Self.sha256(Data(WorkspacePathPolicy.normalize(common).utf8))).prefix(16)
        return root.appendingPathComponent(String(key), isDirectory: true)
    }

    /// The cached checkouts in a repository's folder, most recently used first.
    func entries(in bucket: URL) -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: bucket.path) else { return [] }
        return names.compactMap { name -> Entry? in
            guard let parsed = Self.parseEntryName(name) else { return nil }
            let directory = bucket.appendingPathComponent(name, isDirectory: true)
            let used = (try? fm.attributesOfItem(atPath: directory.path)[.modificationDate] as? Date) ?? .distantPast
            return Entry(directory: directory, tree: parsed.tree, fingerprint: parsed.fingerprint, used: used)
        }
        .sorted { $0.used > $1.used }
    }

    private func gitDirectory(of worktree: String) -> String? {
        let text = (try? git.run(["rev-parse", "--absolute-git-dir"], in: worktree))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Staging folders of builds that never finished (Nook quit halfway), once they are an hour old.
    private func removeLeftovers(in bucket: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: bucket.path)) ?? [] where name.hasPrefix(".staging-") {
            let url = bucket.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(modified) > 3600 { try? fm.removeItem(at: url) }
        }
    }

    private func removeUnusedRepositories(except kept: URL) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            guard url.standardizedFileURL != kept.standardizedFileURL else { continue }
            let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            if Date().timeIntervalSince(modified) > Self.unusedRepositoryAge { try? fm.removeItem(at: url) }
        }
    }

    static func device(_ path: String) -> Int32? {
        var info = stat()
        return stat(path, &info) == 0 ? Int32(truncatingIfNeeded: info.st_dev) : nil
    }

    static func sha256(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: data))
        #else
        // The core tests on Linux have no CryptoKit: the protocol package's pure SHA-256 (WebhookSecurity.swift).
        return Array(PureSHA256.hash(data))
        #endif
    }

    static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
}
