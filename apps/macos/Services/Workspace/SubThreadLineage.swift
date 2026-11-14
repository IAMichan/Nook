import Foundation

// Sub-threads: a delegated task and a side chat live inside their parent's view, never as rows
// of their own in the Agents list. The list stays flat; a fork or a comparison is a session of its own and gets a plain
// row. A sub-thread is still seen in the list through its parent: the parent's row stands in for it while it is open,
// and an approval it waits for shows on the parent's row. The parent's Lineage control lists them all. Foundation only.

/// How a session came from the one it was started from.
enum SubThreadRelation: String, Codable, Sendable {
    /// Another session handed it a task (`Delegation`).
    case delegated
    /// A side chat (/btw, /side) beside its parent's work.
    case side
    /// A copy of the parent's conversation (/fork).
    case fork
    /// The same prompt as the parent, with another model (`ModelComparison`).
    case comparison

    /// Lives inside its parent's view instead of as a row of the list.
    var livesUnderParent: Bool { self == .delegated || self == .side }
}

/// What a sub-thread waits for from you.
enum SubThreadRequest: Equatable, Sendable {
    case approval
    case question
}

/// One session's link to the session it came from, by list id ("run:<uuid>").
struct SubThreadLink: Equatable, Sendable {
    var parent: String
    var relation: SubThreadRelation
}

enum SubThreadListing {
    /// The rows that are left out of the list: a delegated task or side chat whose parent is a row of the list (`listed`,
    /// before anything is left out). One whose parent is gone, archived or not in the list keeps its own row, so it is
    /// never out of reach. A chain hides as a whole: a task of a task follows its parent, which follows the root.
    static func hidden(_ links: [String: SubThreadLink], listed: Set<String>) -> Set<String> {
        Set(links.compactMap { id, link in
            link.relation.livesUnderParent && link.parent != id && listed.contains(link.parent) ? id : nil
        })
    }

    /// The row that stands for `id` in the list: the row itself, or for a hidden sub-thread its nearest listed ancestor.
    /// A loop of parents resolves to `id` itself, which then matches no row.
    static func rowID(for id: String, links: [String: SubThreadLink], hidden: Set<String>) -> String {
        var current = id
        var seen: Set<String> = []
        while hidden.contains(current), seen.insert(current).inserted {
            guard let parent = links[current]?.parent else { return id }
            current = parent
        }
        return hidden.contains(current) ? id : current
    }

    /// The rows to flag for what their sub-threads wait for. A side chat asks
    /// you directly, so its approval and its question both go to its parent. A delegated task's question goes to the agent
    /// that delegated it (`deliverDelegatedQuestion`), so only its approval needs you: that one goes up the chain, through
    /// every parent that is itself a delegated task or a side chat. An approval wins over a question.
    static func requests(_ links: [String: SubThreadLink], open: [String: SubThreadRequest]) -> [String: SubThreadRequest] {
        var flagged: [String: SubThreadRequest] = [:]
        func flag(_ id: String, _ request: SubThreadRequest) {
            if flagged[id] != .approval { flagged[id] = request }
        }
        for (child, request) in open {
            guard let link = links[child], link.parent != child else { continue }
            switch link.relation {
            case .side:
                flag(link.parent, request)
            case .delegated:
                guard request == .approval else { continue }
                var seen: Set<String> = [child]
                var parent: String? = link.parent
                while let id = parent, seen.insert(id).inserted {
                    flag(id, .approval)
                    parent = links[id].flatMap { $0.relation.livesUnderParent ? $0.parent : nil }
                }
            case .fork, .comparison:
                continue
            }
        }
        return flagged
    }
}

// MARK: Lineage control

/// Where a session stands, as the Lineage control shows it.
enum LineageStatus: Equatable, Sendable {
    case working, approval, question, done, failed, stopped

    var isLive: Bool { self == .working || self == .approval || self == .question }
}

/// One session as the Lineage control needs to see it.
struct LineageNode: Equatable, Sendable {
    var id: UUID
    var parentID: UUID?
    var relation: SubThreadRelation?
    var title: String
    var status: LineageStatus
    var createdAt: Date
}

/// The sessions related to one session, in the groups of the lineage panel.
struct LineageGroups: Equatable, Sendable {
    struct Row: Equatable, Sendable {
        enum Role: Equatable, Sendable {
            /// The session this one came from, and how.
            case parent(SubThreadRelation)
            /// A session that came from this one, and how.
            case child(SubThreadRelation)
        }
        var node: LineageNode
        var role: Role
    }

    /// The parent, then the forks and comparisons made from this session.
    var related: [Row] = []
    /// Delegated tasks that still work or wait.
    var active: [Row] = []
    /// Delegated tasks that ended ("Previous agents", folded).
    var previous: [Row] = []
    var sideChats: [Row] = []

    var isEmpty: Bool { related.isEmpty && active.isEmpty && previous.isEmpty && sideChats.isEmpty }
    /// Delegated tasks at work, for the control's label.
    var running: Int { active.count(where: { $0.node.status == .working }) }
    var runningSideChats: Int { sideChats.count(where: { $0.node.status == .working }) }
    /// A related session waits for you.
    var needsYou: Bool {
        (active + sideChats).contains { $0.node.status == .approval || $0.node.status == .question }
    }
    /// Every row, in the order the control lists them.
    var all: [Row] { related + active + previous + sideChats }
}

enum LineageLayout {
    /// The immediate relations of `id`: its parent and its own children, oldest child first. Grandchildren are one step
    /// further, in their parent's control.
    static func groups(for id: UUID, nodes: [LineageNode]) -> LineageGroups {
        var groups = LineageGroups()
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if let me = byID[id], let parentID = me.parentID, parentID != id, let parent = byID[parentID],
           let relation = me.relation {
            groups.related.append(.init(node: parent, role: .parent(relation)))
        }
        let children = nodes
            .filter { $0.parentID == id && $0.id != id && $0.relation != nil }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
        for child in children {
            guard let relation = child.relation else { continue }
            let row = LineageGroups.Row(node: child, role: .child(relation))
            switch relation {
            case .fork, .comparison: groups.related.append(row)
            case .side: groups.sideChats.append(row)
            case .delegated:
                if child.status.isLive { groups.active.append(row) } else { groups.previous.append(row) }
            }
        }
        return groups
    }
}
