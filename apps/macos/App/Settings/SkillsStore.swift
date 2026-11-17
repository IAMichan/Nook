import SwiftUI

/// What Settings › Coding agents › Skills knows while Nook runs: the skills Nook installed for the scope shown, the
/// updates found for them, and the last search. One for the app, so the page keeps its answers when you leave it.
@MainActor
final class SkillsStore: ObservableObject {
    static let shared = SkillsStore()

    /// A newer version of an installed skill: the skill as it is now, and what changed (nil when Nook cannot tell).
    struct Update: Equatable {
        var remote: RemoteSkill
        var change: SkillChange?
    }

    @Published private(set) var installed: [SkillLibraryEntry] = []
    @Published private(set) var updates: [String: Update] = [:]
    @Published private(set) var checking = false
    @Published private(set) var checkError: String?
    @Published private(set) var hits: [SkillSearchHit] = []
    @Published private(set) var searching = false
    @Published private(set) var searchError: String?
    /// The agents a skill is installed for: the ones on this Mac at first.
    @Published var providers: Set<RunProvider>

    private var lastCheck: [SkillScope: Date] = [:]
    private var searchTask: Task<Void, Never>?

    /// Agents with a skills folder Nook knows, in Nook's order.
    static let supported: [RunProvider] = RunProvider.allCases.filter {
        SkillPlaces.root(for: $0, scope: .user, home: URL(fileURLWithPath: "/")) != nil
    }

    private init() {
        let found = Set(Self.supported.filter { AgentUpdater.shared.entries[$0] != nil })
        providers = found.isEmpty ? [.claude] : found
    }

    var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// A fetcher with your GitHub login when there is one (5,000 calls an hour instead of 60).
    var fetcher: SkillFetcher {
        let token = GitHubPullRequests.tokens.first
        return SkillFetcher(token: { token })
    }

    // MARK: Installed

    func reload(_ scope: SkillScope) {
        let home = self.home
        Task {
            let entries = await Task.detached(priority: .userInitiated) {
                SkillLibrary.entries(scope: scope, home: home)
            }.value
            installed = entries
        }
    }

    /// Looks for newer versions of the installed skills: one commit lookup per repository, and the tree only for a
    /// repository that moved on. At most every 30 minutes per scope unless `force`.
    func checkUpdates(_ scope: SkillScope, force: Bool = false) {
        guard !checking else { return }
        if !force, let last = lastCheck[scope], Date().timeIntervalSince(last) < 30 * 60 { return }
        let entries = installed
        guard !entries.isEmpty else { return }
        checking = true
        checkError = nil
        let fetcher = self.fetcher
        Task {
            var found: [String: Update] = [:]
            var failure: String?
            let byRepository = Dictionary(grouping: entries) { entry -> String in
                entry.repository.lowercased() + "@" + (entry.places[0].provenance.ref ?? "")
            }
            for group in byRepository.values {
                let first = group[0].places[0].provenance
                guard var repository = SkillRepository.parse(first.repository) else { continue }
                repository.ref = first.ref
                do {
                    let commit = try await fetcher.commit(of: repository)
                    let stale = group.filter { $0.commit != commit }
                    guard !stale.isEmpty else { continue }
                    let skills = try await fetcher.skills(in: repository, at: commit)
                    for entry in stale {
                        let provenance = entry.places[0].provenance
                        guard let remote = skills.first(where: { $0.folder == provenance.folder }) else { continue }
                        let change = SkillLibrary.change(from: provenance, to: remote)
                        if change?.isEmpty == true { continue }
                        found[entry.id] = Update(remote: remote, change: change)
                    }
                } catch {
                    failure = SkillsStore.message(error)
                }
            }
            updates = found
            checkError = failure
            checking = false
            lastCheck[scope] = Date()
        }
    }

    // MARK: Search

    /// skills.sh's search, a moment after you stop typing; an empty query clears the list.
    func search(_ query: String) {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, WorkspaceSettings.shared.skillsSearchOnline else {
            hits = []
            searching = false
            searchError = nil
            return
        }
        searching = true
        let fetcher = self.fetcher
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            do {
                let found = try await fetcher.search(q)
                guard !Task.isCancelled else { return }
                hits = found
                searchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                hits = []
                searchError = SkillsStore.message(error)
            }
            searching = false
        }
    }

    // MARK: Install, update, remove

    enum Outcome {
        case installed([URL])
        /// A skill with this name from another source is there: ask before replacing it.
        case otherSource(String, SkillProvenance)
        case failed(String)
    }

    /// Downloads the skill and puts it in the folders of `providers` for `scope`; `progress` hears the files arrive.
    func install(_ skill: RemoteSkill, providers: [RunProvider], scope: SkillScope, replace: Bool = false,
                 progress: @escaping @Sendable (Int, Int) -> Void) async -> Outcome {
        let roots = SkillPlaces.roots(for: providers, scope: scope, home: home)
        guard !roots.isEmpty else { return .failed(tr("skills.error.noAgent")) }
        let fetcher = self.fetcher
        do {
            let files = try await fetcher.download(skill, progress: progress)
            let result = await Task.detached(priority: .userInitiated) { () -> Outcome in
                // Check every folder first, so a clash in one does not leave the skill in only some of them.
                if !replace {
                    for root in roots {
                        let destination = root.appendingPathComponent(SkillPaths.installName(skill) ?? skill.folderName)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            guard let current = SkillInstaller.provenance(at: destination) else {
                                return .failed(tr("skills.error.notFromNook", destination.lastPathComponent))
                            }
                            if !current.sameSource(as: skill) { return .otherSource(destination.lastPathComponent, current) }
                        }
                    }
                }
                do {
                    return .installed(try roots.map { try SkillInstaller.install(skill, files: files, into: $0, replace: replace) })
                } catch {
                    return .failed(SkillsStore.message(error))
                }
            }.value
            if case .installed = result { reload(scope) }
            return result
        } catch {
            return .failed(SkillsStore.message(error))
        }
    }

    /// Puts the newer version in every folder the skill is in.
    func update(_ entry: SkillLibraryEntry, to remote: RemoteSkill, progress: @escaping @Sendable (Int, Int) -> Void) async -> Outcome {
        let fetcher = self.fetcher
        do {
            let files = try await fetcher.download(remote, progress: progress)
            let roots = entry.places.map { $0.url.deletingLastPathComponent() }
            let result = await Task.detached(priority: .userInitiated) { () -> Outcome in
                do { return .installed(try roots.map { try SkillInstaller.install(remote, files: files, into: $0) }) }
                catch { return .failed(SkillsStore.message(error)) }
            }.value
            if case .installed = result {
                updates[entry.id] = nil
                reload(entry.scope)
            }
            return result
        } catch {
            return .failed(SkillsStore.message(error))
        }
    }

    /// Removes the skill from every agent folder it is in.
    func remove(_ entry: SkillLibraryEntry) {
        var failed = false
        for place in entry.places {
            do { try SkillInstaller.remove(place.url.lastPathComponent, from: place.url.deletingLastPathComponent()) } catch { failed = true }
        }
        updates[entry.id] = nil
        reload(entry.scope)
        if failed {
            ToastCenter.shared.error(tr("skills.error.remove", entry.name))
        } else {
            ToastCenter.shared.success(tr("skills.removed", entry.name))
        }
    }

    // MARK: Words

    /// An error in words for the page: what went wrong, not Swift's description of it.
    nonisolated static func message(_ error: Error) -> String {
        switch error {
        case let error as SkillFetcher.FetchError:
            switch error {
            case .notFound: return tr("skills.error.notFound")
            case .http(let status, let text):
                if let text, status == 403 || status == 429, GitHubRateLimit.namesLimit(text) { return text }
                return tr("skills.error.http", status)
            case .sizeMismatch(let path): return tr("skills.error.changed", path)
            case .parse(.truncated): return tr("skills.error.truncated")
            case .badAddress, .noCommit, .parse: return tr("skills.error.unreadable")
            }
        case let error as SkillInstaller.InstallError:
            switch error {
            case .refused(let refusal): return refusalText(refusal)
            case .noName: return tr("skills.error.unreadable")
            case .missingFile(let path), .sizeMismatch(let path): return tr("skills.error.changed", path)
            case .notFromNook(let name): return tr("skills.error.notFromNook", name)
            case .otherSource(let name, let record): return tr("skills.error.otherSource", name, record.repository)
            case .write(let path): return tr("skills.error.write", AgentPathFormat.tilde(path))
            }
        case let error as URLError where error.code == .notConnectedToInternet:
            return tr("skills.error.offline")
        default:
            return error.localizedDescription
        }
    }

    nonisolated static func refusalText(_ refusal: SkillRefusal) -> String {
        switch refusal {
        case .link(let path): return tr("skills.refused.link", path)
        case .submodule(let path): return tr("skills.refused.submodule", path)
        case .unsafePath(let path): return tr("skills.refused.path", path)
        case .fileTooLarge(let path, let size): return tr("skills.refused.fileTooLarge", path, byteText(size))
        case .tooLarge(let size): return tr("skills.refused.tooLarge", byteText(size), byteText(SkillLimits.maxSkillBytes))
        case .tooManyFiles(let count): return tr("skills.refused.tooManyFiles", count, SkillLimits.maxFiles)
        }
    }

    nonisolated static func byteText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
