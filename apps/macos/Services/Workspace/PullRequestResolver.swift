import Foundation

/// Turns "#12", "owner/repo#12" or a link into a pull request with its title and state, as the forge says it.
@MainActor
enum PullRequestResolver {
    /// `repository`: the session's own, for a reference without one. Nil when the forge says there is no such pull
    /// request, or when `mustExist` and nobody could ask (no token): an unchecked "#12" may be an issue.
    static func resolve(_ ref: PullRequestRef, repository: RemoteRepository?, mustExist: Bool = false) async -> PullRequestLink? {
        // The session's forge, unless the link names its own.
        guard let host = ref.host ?? repository?.host, let path = ref.repository ?? repository?.path,
              let requestedURL = ref.url ?? { () -> URL? in
                  var target = repository
                  target?.path = path
                  return target?.pullRequestURL(number: ref.number)
              }() else { return nil }
        let store = PullRequestStatusStore.shared
        let canonicalURL = store.canonicalURL(requestedURL)
        let canonicalPath = store.canonicalRepository(host: host, repository: path)
        var link = PullRequestLink(host: host, repository: canonicalPath, number: ref.number, url: canonicalURL.absoluteString)
        if let item = listed(link) { return Self.link(link, from: item, requestedURL: requestedURL) }
        // Another forge with a token answers the same way.
        if let found = ref.forgeRepository ?? repository, let client = PullRequestForges.client(found) {
            guard let detail = try? await client.summary(number: ref.number) else { return nil }
            apply(detail, to: &link, requestedURL: requestedURL)
            return link
        }
        guard host == .github, ref.hostName ?? repository?.hostName == "github.com",
              let account = AccountRegistry.shared.accounts(for: "github").first,
              let token = GitHubPullRequestDetail.token(accountID: account.id) else { return mustExist ? nil : link }
        // GitHub can say whether it exists and what it is called.
        guard let detail = try? await GitHubPullRequestDetail.loadForMerge(repo: canonicalPath, number: ref.number, token: token) else { return nil }
        apply(detail, to: &link, requestedURL: requestedURL)
        return link
    }

    private static func apply(_ detail: PullRequestDetail, to link: inout PullRequestLink, requestedURL: URL) {
        if let url = detail.url {
            PullRequestStatusStore.shared.recordAlias(from: requestedURL, to: url)
            link.url = url.absoluteString
        }
        if !detail.repo.isEmpty { link.repository = detail.repo }
        link.title = detail.title
        link.state = PullRequestState(rawValue: detail.state.rawValue) ?? .open
        link.conflicted = detail.conflicted
        link.headBranch = detail.headBranch
        link.baseBranch = detail.baseBranch
        link.updatedAt = detail.updated
    }

    /// What the pull request list knows of it: it is read anyway, so no request is needed.
    private static func listed(_ link: PullRequestLink) -> PullRequestItem? {
        let key = "\(link.repository)#\(link.number)".lowercased()
        return PullRequestStore.shared.accounts.lazy.compactMap { account in
            (account.mine + account.reviews + account.watched).first { $0.id.lowercased() == key }
        }.first
    }

    private static func link(_ link: PullRequestLink, from item: PullRequestItem, requestedURL: URL) -> PullRequestLink {
        var link = link
        if let url = item.url {
            PullRequestStatusStore.shared.recordAlias(from: requestedURL, to: url)
            link.url = url.absoluteString
        }
        if !item.repo.isEmpty { link.repository = item.repo }
        link.title = item.title
        link.state = item.state == .merged ? .merged : item.state == .closed ? .closed : item.draft ? .draft : .open
        link.conflicted = item.conflict
        link.headBranch = item.headBranch.isEmpty ? nil : item.headBranch
        link.baseBranch = item.baseBranch.isEmpty ? nil : item.baseBranch
        link.updatedAt = item.updated
        return link
    }
}
