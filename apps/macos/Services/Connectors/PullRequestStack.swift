import Foundation

/// Pull requests that build on each other: one whose base branch is another open pull request's head stands on it.
/// The stack runs from the one on the trunk (its base is no pull request's head) up through the ones built on it.
/// Foundation only, so tests can use it. The session-link layering lives on the same type in PullRequestLinks.swift.
extension PullRequestStack {
    /// The stack `item` belongs to, bottom first, or nil when it stands alone. Only open pull requests of the same
    /// repository count; a branch with more than one pull request built on it continues with the lowest number first.
    static func stack(of item: PullRequestItem, in items: [PullRequestItem]) -> [PullRequestItem]? {
        guard item.state == .open, !item.headBranch.isEmpty else { return nil }
        var seen = Set<String>()
        let open = items.filter { $0.state == .open && $0.repo.lowercased() == item.repo.lowercased() && seen.insert($0.id).inserted }
        let byHead = Dictionary(open.map { ($0.headBranch, $0) }, uniquingKeysWith: { first, _ in first })
        // Down to the bottom of the stack; a loop of bases (never on GitHub, but data can lie) stops the walk.
        var path = [open.first { $0.id == item.id } ?? item]
        while let below = byHead[path[path.count - 1].baseBranch], !path.contains(below) {
            path.append(below)
        }
        // Then up, one level at a time: through `item` first, then above it the lowest number on each level.
        var chain = Array(path.reversed())
        while let top = chain.last,
              let above = open.filter({ $0.baseBranch == top.headBranch && !chain.contains($0) }).min(by: { $0.number < $1.number }) {
            chain.append(above)
        }
        return chain.count > 1 ? chain : nil
    }

    /// Where `item` stands in its stack, 1 at the bottom, and how many there are.
    static func position(of item: PullRequestItem, in items: [PullRequestItem]) -> (index: Int, count: Int)? {
        guard let stack = stack(of: item, in: items), let index = stack.firstIndex(where: { $0.id == item.id }) else { return nil }
        return (index + 1, stack.count)
    }

    /// The pull requests to merge to land `item`: from the bottom of its stack up to and including it.
    static func mergeOrder(upTo item: PullRequestItem, in items: [PullRequestItem]) -> [PullRequestItem] {
        guard let stack = stack(of: item, in: items), let index = stack.firstIndex(where: { $0.id == item.id }) else { return [item] }
        return Array(stack[...index])
    }
}
