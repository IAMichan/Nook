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
        return chain(of: item, among: open)
    }

    /// The same stack with the pull requests of it that already merged, so a landed one stays in view. A merged one
    /// counts only while another still names its branch as base: GitHub points those at the trunk once the branch is
    /// deleted, and after that nothing in a pull request says it stood on the other.
    static func history(of item: PullRequestItem, in items: [PullRequestItem]) -> [PullRequestItem]? {
        guard counts(item), !item.headBranch.isEmpty else { return nil }
        return chain(of: item, among: members(items, repo: item.repo))
    }

    /// Whether a pull request can be part of a stack's history. A merged long-lived branch (develop into main) is no
    /// step of a stack, however many pull requests are based on it.
    private static func counts(_ item: PullRequestItem) -> Bool {
        item.state == .open || (item.state == .merged && !BranchPolicy.isDefaultBranch(item.headBranch))
    }

    private static func members(_ items: [PullRequestItem], repo: String) -> [PullRequestItem] {
        var seen = Set<String>()
        return items.filter { counts($0) && !$0.headBranch.isEmpty && $0.repo.lowercased() == repo.lowercased() && seen.insert($0.id).inserted }
    }

    /// Walks from `item` down to the bottom and back up through `members`; nil when it has no neighbour. An open pull
    /// request is preferred over a merged one on the same branch, so the chain follows what is still live.
    private static func chain(of item: PullRequestItem, among members: [PullRequestItem]) -> [PullRequestItem]? {
        let byHead = Dictionary(members.map { ($0.headBranch, $0) }, uniquingKeysWith: { first, second in
            if first.state == .open { return first }
            return second.state == .open || second.number > first.number ? second : first
        })
        // Down to the bottom of the stack; a loop of bases (never on GitHub, but data can lie) stops the walk.
        var path = [members.first { $0.id == item.id } ?? item]
        while let below = byHead[path[path.count - 1].baseBranch], !path.contains(below) {
            path.append(below)
        }
        // Then up, one level at a time: through `item` first, then above it the lowest number on each level.
        var chain = Array(path.reversed())
        while let top = chain.last,
              let above = members.filter({ $0.baseBranch == top.headBranch && !chain.contains($0) })
                .min(by: { ($0.state == .open ? 0 : 1, $0.number) < ($1.state == .open ? 0 : 1, $1.number) }) {
            chain.append(above)
        }
        return chain.count > 1 ? chain : nil
    }

    /// Where `item` stands in its stack, 1 at the bottom, how many there are, and how many of those merged.
    static func position(of item: PullRequestItem, in items: [PullRequestItem]) -> (index: Int, count: Int, merged: Int)? {
        guard let stack = history(of: item, in: items), let index = stack.firstIndex(where: { $0.id == item.id }) else { return nil }
        return (index + 1, stack.count, stack.filter { $0.state == .merged }.count)
    }

    /// Where every pull request of `items` stands in its stack, by id, for a whole list at once. The same answer as
    /// `position(of:in:)` for each, but only the ones with a neighbour are walked, each against its own repository: the
    /// list holds every merged pull request, and most of those stand alone.
    static func positions(in items: [PullRequestItem]) -> [String: (index: Int, count: Int, merged: Int)] {
        var result: [String: (index: Int, count: Int, merged: Int)] = [:]
        let candidates = items.filter { counts($0) && !$0.headBranch.isEmpty }
        for (_, repo) in Dictionary(grouping: candidates, by: { $0.repo.lowercased() }) where repo.count > 1 {
            let heads = Set(repo.map(\.headBranch)), bases = Set(repo.map(\.baseBranch))
            for item in repo where heads.contains(item.baseBranch) || bases.contains(item.headBranch) {
                if let position = position(of: item, in: repo) { result[item.id] = position }
            }
        }
        return result
    }

    /// The pull requests to merge to land `item`: from the bottom of its stack up to and including it.
    static func mergeOrder(upTo item: PullRequestItem, in items: [PullRequestItem]) -> [PullRequestItem] {
        guard let stack = stack(of: item, in: items), let index = stack.firstIndex(where: { $0.id == item.id }) else { return [item] }
        return Array(stack[...index])
    }
}


/// A stack GitHub keeps itself (`/repos/{repo}/stacks`): the layers from the bottom up. Merging a layer lands the ones
/// below it, in one go.
struct PullRequestNativeStack: Equatable, Sendable {
    struct Layer: Equatable, Sendable {
        let number: Int
        let title: String
        let headBranch: String
        let headSHA: String
        let state: PullRequestItem.State
        let draft: Bool
    }

    let number: Int
    let base: String
    let layers: [Layer]

    /// The first stack in GitHub's answer that holds pull requests.
    static func parse(_ answer: Any?) -> PullRequestNativeStack? {
        let stacks = answer as? [[String: Any]] ?? (answer as? [String: Any]).map { [$0] } ?? []
        guard let stack = stacks.first, let number = stack["number"] as? Int else { return nil }
        let base = (stack["base"] as? String) ?? ((stack["base"] as? [String: Any])?["ref"] as? String) ?? ""
        let layers = ((stack["pull_requests"] as? [[String: Any]]) ?? []).compactMap { pull -> Layer? in
            guard let number = pull["number"] as? Int else { return nil }
            let head = pull["head"] as? [String: Any] ?? [:]
            let merged = pull["merged_at"] is String
            let state: PullRequestItem.State = merged ? .merged : (pull["state"] as? String) == "closed" ? .closed : .open
            return Layer(number: number, title: (pull["title"] as? String) ?? "", headBranch: (head["ref"] as? String) ?? "",
                         headSHA: (head["sha"] as? String) ?? "", state: state, draft: (pull["draft"] as? Bool) == true)
        }
        return layers.isEmpty ? nil : PullRequestNativeStack(number: number, base: base, layers: layers)
    }

    /// The layers as the rows the stack menu lists.
    func items(repo: String, like item: PullRequestItem) -> [PullRequestItem] {
        layers.enumerated().map { index, layer in
            var row = PullRequestItem(repo: repo, number: layer.number, title: layer.title,
                                      url: URL(string: "https://github.com/\(repo)/pull/\(layer.number)"), draft: layer.draft, updated: nil, author: "")
            row.state = layer.state
            row.headBranch = layer.headBranch
            row.baseBranch = index == 0 ? base : layers[index - 1].headBranch
            return layer.number == item.number ? item : row
        }
    }
}
