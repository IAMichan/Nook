import SwiftUI

/// What you can do with a file of a session, in its right-click menu: open it in your editor (at
/// `line` when given), show it in Finder, and copy its path. A remote session's file has no path on this Mac, so only its
/// path in the repository can be copied.
struct FileContextMenu: View {
    @EnvironmentObject private var workspace: WorkspaceManager
    let absolutePath: String?
    let relativePath: String
    var line: Int? = nil

    var body: some View {
        if let absolutePath {
            Button(tr("ws.action.openEditor")) { workspace.openFile(FileTarget(path: absolutePath, line: line)) }
            Button(tr("ws.action.reveal")) { workspace.revealInFinder(absolutePath) }
            Divider()
            Button(tr("ws.file.copyPath")) { Pasteboard.copy(absolutePath) }
        }
        Button(tr("ws.file.copyRelative")) { Pasteboard.copy(relativePath) }
    }
}

extension View {
    /// The file menu on a row that shows one changed file of a session.
    func sessionFileMenu(_ workspace: WorkspaceManager, runID: UUID, path: String) -> some View {
        contextMenu {
            FileContextMenu(absolutePath: workspace.absolutePath(runID, repositoryPath: path), relativePath: path)
                .environmentObject(workspace)
        }
    }
}
