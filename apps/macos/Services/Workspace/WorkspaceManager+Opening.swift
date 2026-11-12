import AppKit

/// Opening a session's files and folders in an editor, a terminal or Finder.
extension WorkspaceManager {
    func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        if !settings.editorBundleID.isEmpty,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: settings.editorBundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// Opens a file in your editor with the cursor on its line (`EditorLaunch`): the editor from Settings › Workspace, else
    /// the first known editor on this Mac, else the file is shown in Finder. A file is never handed to its default app,
    /// since an agent's link could point at something that runs.
    func openFile(_ target: FileTarget) {
        let url = URL(fileURLWithPath: target.path)
        guard FileManager.default.fileExists(atPath: target.path) else {
            Task {
                guard let found = await recoverFile(target.path) else {
                    ToastCenter.shared.info(tr("ws.file.missing", AgentPathFormat.tilde(target.path)))
                    return
                }
                var copy = target
                copy.path = found
                openFile(copy)
            }
            return
        }
        let chosen = settings.editorBundleID.isEmpty ? nil : settings.editorBundleID
        let bundleID = chosen ?? WorkspaceSettings.installed(WorkspaceSettings.editorCandidates).first?.bundleID
        guard !target.path.hasSuffix(".app"), let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            revealInFinder(target.path)
            return
        }
        let executable = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
        if case .process(let tool, let arguments) = EditorLaunch.plan(bundleID: bundleID, appPath: app.path, executable: executable, target: target),
           FileManager.default.isExecutableFile(atPath: tool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            if (try? process.run()) != nil { return }
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A changed file of a session, by its path in the repository, at an absolute path (nil for a remote session).
    func absolutePath(_ id: UUID, repositoryPath: String) -> String? {
        guard let run = run(id), !run.isRemote else { return nil }
        let root = run.worktreePath ?? run.repoRoot ?? run.workingDirectory
        return ((root as NSString).appendingPathComponent(repositoryPath) as NSString).standardizingPath
    }

    func openTerminal(_ path: String) {
        if settings.terminalBundleID == WorkspaceSettings.builtInTerminal, let openBuiltInTerminal {
            openBuiltInTerminal(path)
            return
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let bundle = settings.terminalBundleID.isEmpty || settings.terminalBundleID == WorkspaceSettings.builtInTerminal
            ? "com.apple.Terminal" : settings.terminalBundleID
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
