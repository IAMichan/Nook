import Foundation

/// `render_page`: an agent shows a page inline in its own session's timeline (see `RenderedPage`). The page is kept as a
/// file next to Nook's other data, owner-only, and drawn in a sandbox; the call is in the audit log with its title and size.
extension WorkspaceBridge {
    func renderPage(_ arguments: [String: Any], _ caller: BridgeCaller) -> BridgeRPC.ToolResult {
        guard case .run(let runID) = caller.kind, let workspace = app?.workspace, workspace.run(runID) != nil else {
            return .error("render_page shows the page in a session Nook runs; this session runs outside Nook, so there is no timeline to show it in.")
        }
        if case .refuse(let reason) = verdict(.renderPage, caller) { return .error(Self.refusal(reason)) }
        let request: RenderedPage.Request
        switch RenderedPage.parse(arguments) {
        case .failure(let error): return .error(error.message)
        case .success(let value): request = value
        }
        let pageID = UUID()
        let file = RenderedPage.file(in: NookPaths.supportDirectory, run: runID, page: pageID)
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path))?.count ?? 0
        guard kept < RenderedPage.maxPagesPerRun else {
            return .error("This session already shows \(RenderedPage.maxPagesPerRun) pages, the most one session keeps. Say it in words, or update the idea in a new session.")
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(request.html.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return .error("Nook could not keep the page: \(error.localizedDescription)")
        }
        workspace.append(runID, RenderedPage.event(id: pageID, title: request.title, file: file.path, height: request.height))
        audit(.renderPage, caller, request.title, "\(request.html.utf8.count) bytes")
        return BridgeRPC.ToolResult(text: "Shown in your session's timeline as \"\(request.title)\", \(Int(request.height)) points high. It runs sandboxed: no network, no access to Nook or files, nothing it does comes back to you.")
    }
}
