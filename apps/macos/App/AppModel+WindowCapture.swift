import AppKit

/// The window capture shortcut (⌥⌘5 by default) and ⌥-dragging Nook onto a window: the window's picture and its text go
/// to the composer of the session you work in, or to the Nook chat (Settings › Shortcuts, `WindowCaptureTarget`).
extension AppModel {
    /// Captures the front window. Needs Screen Recording (asked for as everywhere else in Nook); its text comes from
    /// Accessibility when Nook has it, otherwise from the picture.
    func captureFrontWindow() {
        guard ScreenAccess.isUsable else {
            ScreenAccess.clearStaleGrant()
            _ = CGRequestScreenCaptureAccess()
            viewModel.present(errorCard(tr("chat.capture.permission")))
            return
        }
        guard let front = WindowCapture.frontWindow() else {
            ToastCenter.shared.warning(tr("windowCapture.noWindow"))
            return
        }
        Task { @MainActor [weak self] in
            guard let image = await WindowAttach.capture(front.target.windowID) else {
                ToastCenter.shared.error(tr("attach.window.failed", front.target.app))
                return
            }
            self?.deliverCapture(image, target: front.target, pid: front.pid)
        }
    }

    /// The process that owns a window, for reading its text.
    static func ownerPID(of windowID: CGWindowID) -> pid_t? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first else { return nil }
        return info[kCGWindowOwnerPID as String] as? pid_t
    }

    /// Hands a captured window to where captures go: the session's composer (as a picture and a text file the agent
    /// reads) or the Nook chat. Without a session to take it, the chat does.
    func deliverCapture(_ image: CGImage, target: WindowAttach.Target, pid: pid_t?) {
        let name = target.title.isEmpty ? target.app : "\(target.app) — \(target.title)"
        Task { @MainActor [weak self] in
            let read = await WindowCapture.text(of: pid, image: image)
            guard let self else { return }
            if WindowCaptureTarget.current() == .session, let session = self.captureSession() {
                self.captureIntoSession(image, name: name, target: target, text: read, session: session)
            } else {
                self.captureIntoChat(image, name: name, app: target.app, recognized: read.text)
            }
        }
    }

    /// The session a capture goes to: the one open in the Agents tab, else the session Nook runs that was busy last.
    func captureSession() -> (target: SessionContextTarget, title: String, open: () -> Void)? {
        let id = viewModel.selectedAgentID
        if id.hasPrefix("run:"), let uuid = UUID(uuidString: String(id.dropFirst(4))), let run = workspace.run(uuid), !run.archived {
            return (SessionContextTarget(run: uuid, directory: run.workingDirectory), run.title, { [weak self] in self?.openWorkspace(run: uuid) })
        }
        if let live = hub.sessions.first(where: { $0.id == id }), !live.cwd.isEmpty {
            return (SessionContextTarget(run: nil, directory: live.cwd), live.name, { [weak self] in
                self?.viewModel.selectedAgentID = id
                self?.viewModel.show(.panel(.agents))
            })
        }
        guard let run = workspace.runs.filter({ !$0.archived }).max(by: { $0.updatedAt < $1.updatedAt }) else { return nil }
        return (SessionContextTarget(run: run.id, directory: run.workingDirectory), run.title, { [weak self] in self?.openWorkspace(run: run.id) })
    }

    private func captureIntoSession(_ image: CGImage, name: String, target: WindowAttach.Target,
                                    text: (text: String, source: WindowCaptureText.Source),
                                    session: (target: SessionContextTarget, title: String, open: () -> Void)) {
        let picture = ImageAttachment(image: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)), name: name)
        var files: [ContextRef] = []
        if !text.text.isEmpty, let file = Self.saveCaptureText(WindowCaptureText.document(app: target.app, title: target.title,
                                                                                          text: text.text, source: text.source), name: name) {
            files.append(ContextRef(kind: .file, id: file.path, label: file.lastPathComponent))
        }
        // The session opens first, so its composer is on screen to take the capture.
        session.open()
        openWindow(continuing: .agents)
        ComposerInbox.shared.add(images: picture.map { [$0] } ?? [], files: files, to: session.target,
                                 confirmation: tr("windowCapture.added", name, session.title))
    }

    /// The Nook chat: the picture with its text, to ask about (as ⌥-dragging Nook onto a window always did).
    private func captureIntoChat(_ image: CGImage, name: String, app: String, recognized: String) {
        guard let encoded = ChatImage.encode(image) else { return }
        showChat()
        attachment = (name, ChatImage.describe(name: name, recognized: recognized), Date())
        attachmentImages = [encoded]
        var message = ChatMessage(role: .nook, text: tr("attach.window.done", name))
        message.sources = [app]
        chat.append(message)
    }

    /// The window's text as a file the agent reads itself, beside the other captures (the ten latest are kept).
    private static func saveCaptureText(_ text: String, name: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NookCaptures", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        pruneCaptures(in: folder)
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").prefix(60)
        let file = folder.appendingPathComponent("\(safe) \(Int(Date().timeIntervalSince1970)).txt")
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }
}
