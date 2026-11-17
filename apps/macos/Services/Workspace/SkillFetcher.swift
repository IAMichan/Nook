import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The network side of skills from the internet. Per skill it costs two GitHub API calls (the commit, then the tree);
// the files themselves come from raw.githubusercontent.com at that commit, which does not count against the API's
// limit (60 an hour without an account). A GitHub token, when there is one, only goes to api.github.com.

struct SkillFetcher: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    enum FetchError: Error, Equatable {
        case badAddress
        case http(Int, String?)
        case notFound
        case noCommit
        /// A file arrived with another size than the repository's tree lists.
        case sizeMismatch(String)
        case parse(SkillCatalog.ParseError)
    }

    var transport: Transport
    /// A GitHub token for api.github.com (5,000 calls an hour instead of 60); nil reads anonymously.
    var token: @Sendable () -> String?
    var searchOrigin = "https://skills.sh"
    var apiOrigin = "https://api.github.com"
    var rawOrigin = "https://raw.githubusercontent.com"
    /// Files fetched at the same time for one skill.
    var parallelDownloads = 6

    init(transport: @escaping Transport = SkillFetcher.urlSession, token: @escaping @Sendable () -> String? = { nil }) {
        self.transport = transport
        self.token = token
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        configuration.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: configuration)
    }()

    static let urlSession: Transport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FetchError.http(0, nil) }
        return (data, http)
    }

    // MARK: Search

    /// skills.sh's search: names, repositories and install counts, most installed first as skills.sh ranks them.
    func search(_ query: String, limit: Int = 20) async throws -> [SkillSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var parts = URLComponents(string: searchOrigin + "/api/search")
        parts?.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(limit))]
        guard let url = parts?.url else { throw FetchError.badAddress }
        let data = try await get(url, api: false)
        do { return try SkillCatalog.searchHits(data) } catch let e as SkillCatalog.ParseError { throw FetchError.parse(e) }
    }

    // MARK: Repository

    /// The commit a repository's ref (or default branch) points at now.
    func commit(of repository: SkillRepository) async throws -> String {
        let ref = repository.ref.flatMap { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) } ?? "HEAD"
        guard let url = URL(string: "\(apiOrigin)/repos/\(repository.slug)/commits/\(ref)") else { throw FetchError.badAddress }
        guard let sha = SkillCatalog.commitSHA(try await get(url, api: true)) else { throw FetchError.noCommit }
        return sha
    }

    /// Every skill in the repository (or its folder) at a commit, named by folder until `describe` reads them.
    func skills(in repository: SkillRepository, at commit: String) async throws -> [RemoteSkill] {
        guard let url = URL(string: "\(apiOrigin)/repos/\(repository.slug)/git/trees/\(commit)?recursive=1") else { throw FetchError.badAddress }
        let data = try await get(url, api: true)
        do { return try SkillCatalog.skills(inTree: data, repository: repository, commit: commit) }
        catch let e as SkillCatalog.ParseError { throw FetchError.parse(e) }
    }

    /// Reads a skill's SKILL.md (its head only) for the name and description in its front matter.
    func describe(_ skill: RemoteSkill) async throws -> RemoteSkill {
        var described = skill
        let data = try await file(skill, path: "SKILL.md")
        described.describe(skillFile: String(decoding: data.prefix(SkillIndex.maxFileBytes), as: UTF8.self))
        return described
    }

    /// The skill a search hit means, described, at the repository's current commit.
    func resolve(_ hit: SkillSearchHit) async throws -> RemoteSkill {
        let sha = try await commit(of: hit.repository)
        let all = try await skills(in: hit.repository, at: sha)
        if let byFolder = all.first(where: { $0.folderName.lowercased() == hit.skillID.lowercased() }) {
            return try await describe(byFolder)
        }
        // The id is the front matter's name, not the folder's: read the SKILL.md files (a few at a time) to find it.
        for chunk in stride(from: 0, to: min(all.count, 120), by: parallelDownloads).map({ Array(all[$0..<min($0 + parallelDownloads, all.count)]) }) {
            let described = await withTaskGroup(of: RemoteSkill?.self) { group in
                for skill in chunk { group.addTask { try? await describe(skill) } }
                return await group.reduce(into: [RemoteSkill]()) { if let s = $1 { $0.append(s) } }
            }
            if let found = SkillCatalog.match(hit, in: described) { return found }
        }
        throw FetchError.notFound
    }

    /// Every file of the skill at its commit, with the sizes the tree promised (checked again when installing).
    /// `progress` hears how many of the files have arrived, from any thread.
    func download(_ skill: RemoteSkill, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> [String: Data] {
        if let refusal = skill.refusal ?? SkillCatalog.limitRefusal(skill.files) { throw SkillInstaller.InstallError.refused(refusal) }
        var out: [String: Data] = [:]
        var queue = skill.files[...]
        while !queue.isEmpty {
            let batch = queue.prefix(parallelDownloads)
            queue = queue.dropFirst(batch.count)
            try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for file in batch {
                    group.addTask {
                        let data = try await self.file(skill, path: file.path)
                        // Not what the tree listed: refuse rather than install something that was not previewed.
                        guard data.count == file.size else { throw FetchError.sizeMismatch(file.path) }
                        return (file.path, data)
                    }
                }
                for try await (path, data) in group {
                    out[path] = data
                    progress?(out.count, skill.files.count)
                }
            }
        }
        return out
    }

    // MARK: Requests

    /// One file of the skill at its commit (for the preview: SKILL.md and each script).
    func file(_ skill: RemoteSkill, path: String) async throws -> Data {
        let full = skill.folder.isEmpty ? path : skill.folder + "/" + path
        guard let encoded = full.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(rawOrigin)/\(skill.repository.slug)/\(skill.commit)/\(encoded)") else { throw FetchError.badAddress }
        return try await get(url, api: false)
    }

    private func get(_ url: URL, api: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Nook", forHTTPHeaderField: "User-Agent")
        if api {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token = token(), !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        }
        let (data, response) = try await transport(request)
        switch response.statusCode {
        case 200..<300: return data
        case 404: throw FetchError.notFound
        default:
            let text = String(data: data.prefix(2048), encoding: .utf8)
            throw FetchError.http(response.statusCode, GitHubRateLimit.message(response, text) ?? text)
        }
    }
}
