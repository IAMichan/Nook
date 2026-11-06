import Foundation

/// One line of a session's own pull request list: the pull request, how it got there, and where it stands in a chain of
/// pull requests built on each other.
struct LinkedPullRequest: Equatable, Identifiable, Sendable {
    enum Source: String, Sendable {
        /// The branch the session is on now.
        case branch
        /// A branch the session worked on before.
        case earlierBranch
        /// You linked it yourself.
        case you
    }

    var link: PullRequestLink
    var source: Source
    /// 0 for one that stands on its own or at the bottom of a chain; one more for each pull request it is built on.
    var depth: Int
    /// How many pull requests its chain has, itself included; 1 when it stands alone.
    var stackSize: Int

    var id: String { link.id }
}

enum LinkedPullRequests {
    /// The list as it reads from top to bottom: each chain from its bottom up, indented by depth, open chains first and
    /// the newest of those on top. A pull request found twice keeps the source closest to the session.
    static func lines(branch: [PullRequestLink], earlier: [PullRequestLink], yours: [PullRequestLink],
                      dismissed: Set<String>) -> [LinkedPullRequest] {
        var sources: [String: LinkedPullRequest.Source] = [:]
        var unique: [PullRequestLink] = []
        let found: [(links: [PullRequestLink], source: LinkedPullRequest.Source)] = [(branch, .branch), (yours, .you), (earlier, .earlierBranch)]
        for (links, source) in found {
            for link in links where !dismissed.contains(link.id) && sources[link.id] == nil {
                sources[link.id] = source
                unique.append(link)
            }
        }
        var children: [String: [PullRequestLink]] = [:]
        var roots: [PullRequestLink] = []
        for link in unique {
            if let parent = PullRequestStack.parent(of: link, in: unique) {
                children[parent.id, default: []].append(link)
            } else {
                roots.append(link)
            }
        }
        var lines: [LinkedPullRequest] = []
        var placed = Set<String>()
        func walk(_ link: PullRequestLink, depth: Int, into chain: inout [PullRequestLink], depths: inout [String: Int]) {
            guard placed.insert(link.id).inserted else { return }
            chain.append(link)
            depths[link.id] = depth
            for child in (children[link.id] ?? []).sorted(by: { $0.number < $1.number }) {
                walk(child, depth: depth + 1, into: &chain, depths: &depths)
            }
        }
        func place(_ root: PullRequestLink) -> (chain: [PullRequestLink], depths: [String: Int]) {
            var chain: [PullRequestLink] = []
            var depths: [String: Int] = [:]
            walk(root, depth: 0, into: &chain, depths: &depths)
            return (chain, depths)
        }
        var chains = roots.map(place)
        // Pull requests that point at each other have no bottom: each still gets a line.
        chains += unique.filter { !placed.contains($0.id) }.map(place)
        chains = chains.filter { !$0.chain.isEmpty }.sorted { left, right in
            let (leftOpen, rightOpen) = (left.chain.contains { $0.state.isOpen }, right.chain.contains { $0.state.isOpen })
            if leftOpen != rightOpen { return leftOpen }
            return (left.chain.map(\.number).max() ?? 0) > (right.chain.map(\.number).max() ?? 0)
        }
        for (chain, depths) in chains {
            for link in chain {
                lines.append(LinkedPullRequest(link: link, source: sources[link.id] ?? .branch, depth: depths[link.id] ?? 0,
                                               stackSize: chain.count))
            }
        }
        return lines
    }

    static func openCount(_ lines: [LinkedPullRequest]) -> Int { lines.filter(\.link.state.isOpen).count }
}
