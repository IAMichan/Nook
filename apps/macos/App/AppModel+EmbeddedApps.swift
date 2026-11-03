import SwiftUI

/// Apps inside Nook: "@open whatsapp" shows WhatsApp Web next to the chat, so you chat in the app itself and with Nook
/// about it side by side; "@chat Jan" shows Jan's chat the way a new message from Jan shows (with a linked phone),
/// else opens it in WhatsApp beside the chat. "@close" puts it away again (it stays signed in).
extension AppModel {
    /// Handles "@open …", "@whatsapp", "@chat Jan" and "@close" from the chat. False when the text is no
    /// such command.
    func handleEmbeddedAppCommand(_ text: String) -> Bool {
        guard let command = EmbeddedAppCatalog.command(in: text) else { return false }
        chat.append(ChatMessage(role: .user, text: text))
        switch command {
        case .open(let app, _) where EmbeddedArtifact.app(for: app.url) != nil:
            // "@open claude.ai/artifact/…": beside Claude, signed in, rather than as a site of its own.
            if let owner = openArtifact(app.url) {
                chat.append(ChatMessage(role: .nook, text: tr("embedded.artifact.opened", tr("embedded.artifact"), owner.title)))
            }
        case .open(let app, let mode):
            let opened = openEmbeddedApp(app, mode: mode)
            chat.append(ChatMessage(role: .nook, text: openedMessage(opened.app, opened.mode, chosen: opened.chosen)))
        case .close:
            let title = EmbeddedAppStore.shared.current?.title
            Task { await closeEmbeddedApp() }
            chat.append(ChatMessage(role: .nook, text: title.map { tr("embedded.closed", $0) } ?? tr("embedded.nothingOpen")))
        case .chat(let name):
            // Every chat Nook has opens as the card a new message brings up (its messages so far and a field to answer),
            // the same for every app; WhatsApp's linked phone fetches the chat first (`openWhatsAppChat`).
            if WhatsAppAccounts.shared.resolve(name) == nil,
               let id = chatsEntryID(named: name), let thread = ChatCaptureService.shared.loadedInbox.threads[id] {
                chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.card", thread.name)))
                presentChat(id, asked: true)
                return true
            }
            openWhatsAppChat(name)
        case .unknown(let name):
            let names = EmbeddedAppCatalog.suggestions(for: name).map { "@open " + $0.title }.joined(separator: ", ")
            chat.append(ChatMessage(role: .nook, text: tr("embedded.unknown", name, names)))
        }
        showChat()
        return true
    }

    /// Opens `app` the way asked for, else the way you chose last time for it, else beside the chat. A way asked for is
    /// remembered when the app has more than one. `chosen`: the way came from you, now or before.
    @discardableResult
    func openEmbeddedApp(_ app: EmbeddedApp, mode: EmbeddedAppMode? = nil) -> (app: EmbeddedApp, mode: EmbeddedAppMode, chosen: Bool) {
        let wanted = mode ?? (app.isMacApp ? EmbeddedAppPreference.mode(for: app) : nil)
        let (target, way) = EmbeddedAppCatalog.resolve(app, mode: wanted)
        if mode != nil, EmbeddedAppCatalog.modes(for: target).count > 1 { EmbeddedAppPreference.remember(way, for: target) }
        if way == .window {
            // Outside Nook: the app itself in front, in its own window; nothing stays beside the chat.
            EmbeddedAppStore.shared.close()
            viewModel.embeddedAppOpen = false
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: target.url, configuration: configuration) { _, _ in }
        } else {
            EmbeddedAppStore.shared.open(target)
            // One thing beside the chat at a time: the app takes the browser's and the terminal's place.
            viewModel.browserBesideChat = false
            viewModel.terminalBesideChat = nil
            viewModel.embeddedAppOpen = true
        }
        return (target, way, wanted != nil)
    }

    /// An artifact clicked or opened in Nook (a Claude artifact, a ChatGPT canvas): the app that made it opens beside the
    /// chat in its web version, with the artifact in a side panel next to it, signed in with the app so a private one
    /// shows too. In an agent's conversation (`beside`) it opens as a tab of the session's side panel instead, without
    /// opening the app. Returns that app; nil when `url` is no artifact.
    @discardableResult
    func openArtifact(_ url: URL, beside: Bool = false) -> EmbeddedApp? {
        guard let owner = EmbeddedArtifact.app(for: url) else { return nil }
        let store = EmbeddedAppStore.shared
        if beside, !demoMode {
            // Clicked in an agent's conversation: it loads in the session's side panel, in Nook, signed in with the app.
            store.openArtifact(url, of: owner)
            viewModel.sessionTool = .artifact
            return owner
        }
        if store.current?.id != owner.id { store.open(owner) }
        viewModel.browserBesideChat = false
        viewModel.terminalBesideChat = nil
        viewModel.embeddedAppOpen = true
        store.openBeside(url)
        showChat()
        return owner
    }

    /// A web link clicked in an agent's conversation opens in the session's side panel, its
    /// integrated browser: an artifact in its own tab, signed in with the app that made it, any other page in
    /// the browser tab. The link target setting or ⌘ or ⌃ held while clicking sends it to the system browser instead
    /// (false: the caller opens it); `forced` (the link's right-click menu) opens it in the panel whatever they say.
    @discardableResult
    func openLinkBeside(_ url: URL, forced: Bool = false) -> Bool {
        guard !demoMode, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              forced || (AgentLinkTarget.current() == .app && NSEvent.modifierFlags.isDisjoint(with: [.command, .control]))
        else { return false }
        if openArtifact(url, beside: true) != nil { return true }
        BrowserStore.shared.open(url)
        viewModel.sessionTool = .browser
        return true
    }

    /// A file link opens in Nook's own viewer at its line: in the session's side panel when clicked in an agent's
    /// conversation (`beside`), else in a window of its own. ⌘ or ⌃ held while clicking opens it in your editor
    /// instead, and a folder shows in Finder. Nothing is handed to the file's own app.
    func openFileInNook(_ target: FileTarget, beside: Bool) {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isFolder) else {
            // Gone with its worktree (after the pull request merged, say): its kept copy, or the file from git.
            Task {
                guard let found = await workspace.recoverFile(target.path) else {
                    ToastCenter.shared.info(tr("ws.file.missing", AgentPathFormat.tilde(target.path)))
                    return
                }
                var copy = target
                copy.path = found
                openFileInNook(copy, beside: beside)
            }
            return
        }
        if isFolder.boolValue {
            workspace.revealInFinder(target.path)
        } else if !NSEvent.modifierFlags.isDisjoint(with: [.command, .control]) {
            workspace.openFile(target)
        } else if beside {
            FileViewerStore.shared.open(target)
            viewModel.sessionTool = .file
        } else {
            FileViewerWindow.shared.show(target)
        }
    }

    /// A pull request a session just made opens as a pull request in the side panel beside that session, while you
    /// look at it; elsewhere its row and the tray above its composer show it. Each one once, whoever saw it first (the
    /// tool that made it, the end of the agent's turn, the sync that found it). Without a GitHub connection that can
    /// read it, it opens in Nook's browser, never in another app.
    func showCreatedPullRequest(_ url: URL, run id: UUID?) {
        if let id, !(viewModel.isShowing(.agents) && viewModel.selectedAgentID == "run:" + id.uuidString) { return }
        guard CreatedPullRequests.shown.insert(url.absoluteString.lowercased()).inserted else { return }
        if !openPullRequestLink(url, beside: true) { BrowserStore.show(url) }
    }

    /// A github.com pull request link opens in Nook, read with the account that lists it (else the first GitHub
    /// account): in the session's side panel when clicked in an agent's conversation (`beside`), else on the Pull
    /// requests page. Its top bar opens it on GitHub. Returns false when Nook cannot read it (another forge, GitHub
    /// not connected), so the link opens in the browser instead. A github.com pull request that only fails because
    /// GitHub is not connected (or its token cannot be read) says so, so the web page does not open unexplained.
    @discardableResult
    func openPullRequestLink(_ url: URL, beside: Bool = false) -> Bool {
        guard let request = pullRequestRequest(for: url) else {
            if !demoMode, !GitHubPullRequestList.isAvailable, PullRequestRef.gitHubItem(url) != nil {
                ToastCenter.shared.info(tr("agents.pr.openUnavailable"))
            }
            return false
        }
        // GitHub is asked now, not once the page has slid in and appeared; the page picks up the read that runs.
        PullRequestDetailModel.prefetch(accountID: request.account, item: request.item)
        if beside {
            viewModel.openSidePullRequest(request)
            return true
        }
        viewModel.pullRequestToOpen = request
        viewModel.selectedAgentID = AgentsPage.pullRequests
        viewModel.show(.panel(.agents))
        return true
    }

    /// A github.com pull request link as Nook opens it: with the account that lists it (else the first GitHub account)
    /// and what the list knows of it. Nil when Nook cannot read it (another forge, GitHub not connected).
    func pullRequestRequest(for url: URL) -> PullRequestOpenRequest? {
        guard !demoMode, GitHubPullRequestList.isAvailable, let link = PullRequestRef.gitHubItem(url) else { return nil }
        let key = link.id.lowercased()
        let listed = PullRequestStore.shared.accounts.lazy.compactMap { account in
            (account.mine + account.reviews + account.watched).first { $0.id.lowercased() == key }.map { (account.id, $0) }
        }.first
        let account = listed?.0 ?? AccountRegistry.shared.accounts(for: "github").first?.id ?? "github"
        return PullRequestOpenRequest(account: account, item: listed?.1 ?? link)
    }

    /// Reads ahead the pull request a conversation links last, so clicking the link shows it at once.
    func prefetchPullRequestLink(_ url: URL) {
        guard let request = pullRequestRequest(for: url) else { return }
        PullRequestDetailModel.prefetch(accountID: request.account, item: request.item, priority: .utility)
    }

    /// "@chat Jan": with a linked phone, Jan's chat shows as the card a new message from Jan brings up (the chat so
    /// far and a field to answer). Without one WhatsApp opens next to the chat, the way you open it ("@open whatsapp"),
    /// with Jan's chat in it: in WhatsApp Web Nook searches the chat and clicks it, and in the Mac app you pick it there
    /// yourself. Nothing is typed or marked read.
    func openWhatsAppChat(_ name: String) {
        // A linked phone knows the chat's exact name and number (in whichever account it is); without one the name goes
        // as typed.
        if let found = WhatsAppAccounts.shared.resolve(name) {
            openWhatsAppCard(found.key, name: found.name)
            return
        }
        let target = WhatsAppLink.shared.resolve(name)
        guard let whatsApp = EmbeddedAppCatalog.find("whatsapp") else { return }
        let shown = target?.name ?? name
        let opened = openEmbeddedApp(whatsApp)
        switch opened.mode {
        case .web:
            chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.opening", shown)))
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await EmbeddedAppStore.shared.openWhatsAppChat(shown)
                } catch {
                    // Closed or switched away in the meantime: there is nothing left to tell.
                    guard EmbeddedAppStore.shared.current?.id == opened.app.id else { return }
                    self.chat.append(ChatMessage(role: .nook, text: error.localizedDescription))
                }
            }
        case .mirror, .window:
            guard let link = target.flatMap({ WAJID.appLink($0.jid) }) else {
                chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.pick", opened.app.title, shown)))
                break
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = opened.mode == .window
            NSWorkspace.shared.open([link], withApplicationAt: opened.app.url, configuration: configuration) { _, _ in }
            chat.append(ChatMessage(role: .nook, text: tr(opened.mode == .window ? "whatsapp.open.window" : "whatsapp.open.opened", shown)))
        }
    }

    /// The card for one chat, asked for: its messages from the phone first (a chat that never wrote since Nook started
    /// has none here yet), then the card in front of the chat. `key` is the chat's key across accounts (`WAChatKey`).
    private func openWhatsAppCard(_ key: String, name: String) {
        let (link, jid) = WhatsAppAccounts.shared.route(key)
        let chat = WAJID.normalized(jid)
        self.chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.card", name)))
        Task { @MainActor [weak self] in
            _ = await link.loadHistory(chat)
            if link.inbox.conversations[chat]?.messages.isEmpty ?? true {
                _ = try? await link.messages(of: chat, limit: WAInbox.keep)
            }
            guard let self else { return }
            guard link.inbox.conversations[chat]?.messages.isEmpty == false else {
                self.chat.append(ChatMessage(role: .nook, text: tr("whatsapp.open.empty", name)))
                return
            }
            // The chat as the shared inbox has it once the link's news is in, then its card as every app's.
            let capture = ChatCaptureService.shared
            await capture.readAndWait(capture.whatsAppGatewayBridge)
            self.presentChat(ChatInbox.key(app: capture.whatsAppGatewayBridge.app, id: link.chatKey(chat)), asked: true)
        }
    }

    /// Opens the app beside the chat another way, chosen at the top of its pane, and remembers that for next time.
    func switchEmbeddedApp(to mode: EmbeddedAppMode) {
        guard let current = EmbeddedAppStore.shared.current else { return }
        let opened = openEmbeddedApp(current, mode: mode)
        if opened.mode == .window {
            chat.append(ChatMessage(role: .nook, text: openedMessage(opened.app, opened.mode, chosen: true)))
        }
    }

    /// What Nook says after opening an app. Until you have chosen a way for an app that has more than one, it says how.
    private func openedMessage(_ app: EmbeddedApp, _ mode: EmbeddedAppMode, chosen: Bool) -> String {
        if mode == .window { return tr("embedded.openedWindow", app.title, app.title) }
        let opened = tr("embedded.opened", app.title)
        guard !chosen, EmbeddedAppCatalog.modes(for: app).count > 1 else { return opened }
        return opened + " " + tr("embedded.otherWays", app.title)
    }

    /// Puts the app away. `forget`: also signs out of it on this Mac.
    func closeEmbeddedApp(forget: Bool = false) async {
        if forget { await EmbeddedAppStore.shared.forget() } else { EmbeddedAppStore.shared.close() }
        viewModel.embeddedAppOpen = false
    }

    /// For the context: which app is open next to the chat, so "what does Arjan say?" is read from it.
    var embeddedAppContextLine: String? {
        guard let app = EmbeddedAppStore.shared.current else { return nil }
        var line = "Open next to the chat (inside Nook): \(app.title). Read what it shows with read_open_app when the user asks about it."
        if !EmbeddedAppStore.whatsAppWebTools.isEmpty {
            line += " WhatsApp messages to a contact or group go through it with whatsapp_send (the user approves the exact text first)."
        }
        return line
    }
}

/// The pull requests `showCreatedPullRequest` opened already.
@MainActor
private enum CreatedPullRequests {
    static var shown = Set<String>()
}
