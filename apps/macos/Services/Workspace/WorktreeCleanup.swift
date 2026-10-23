import Foundation

/// The worktree a session leaves behind when you delete it: its own worktree, when no
/// other session works in it or below it. A session in your main checkout leaves nothing to remove.
enum WorktreeCleanup {
    static func orphaned(worktree: String?, otherFolders: [String]) -> String? {
        guard let worktree, !worktree.isEmpty else { return nil }
        let root = WorkspacePathPolicy.normalize(worktree)
        let shared = otherFolders.contains { folder in
            let other = WorkspacePathPolicy.normalize(folder)
            return other == root || other.hasPrefix(root + "/")
        }
        return shared ? nil : worktree
    }
}
