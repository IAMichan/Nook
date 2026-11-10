import AppKit

/// Links macOS hands to Nook: its own `nook://` links (a prompt, a session) and, while Nook is the default browser, web
/// links and web pages from other apps (`IncomingLinkRoute`).
extension AppModel {
    func openIncoming(_ urls: [URL]) {
        for url in urls {
            switch IncomingLinkRoute.decide(url, target: IncomingLinkTarget.current(),
                                            panelShowsBrowser: SessionBrowsers.shared.shownInPanel != nil,
                                            sessionOnScreen: SessionBrowsers.shared.sessionOnScreen) {
            case .nookLink: openNookLink(url)
            case .sessionPanel:
                guard let store = SessionBrowsers.shared.shownInPanel else { continue }
                openInNewTab(url, store)
            case .sessionBrowser:
                openInNewTab(url, SessionBrowsers.shared.inView)
                viewModel.sessionTool = .browser
                openWindow(continuing: .agents)
            case .nookBrowser:
                openInNewTab(url, BrowserStore.shared)
                viewModel.selectedAgentID = AgentsPage.browser
                openWindow(continuing: .agents)
            case .previousBrowser:
                DefaultBrowser.openOutside(url)
            }
        }
    }

    /// A link joins the browser as a tab of its own, so the page you had stays; an empty tab is used as it is.
    private func openInNewTab(_ url: URL, _ store: BrowserStore) {
        if store.pageURL != nil { store.newTab() }
        store.open(url)
    }

    /// `nook://prompt?text=…` fills a draft in a new session, never sends it (see PromptLink); `nook://session/…` opens
    /// that session (see SessionLink).
    private func openNookLink(_ url: URL) {
        if let link = PromptLink.parse(url: url) {
            if let pull = link.pullRequest {
                openPullRequestLink(link, pull)
                return
            }
            PromptLinkInbox.shared.pending = link
            viewModel.selectedAgentID = "new"
            viewModel.show(.panel(.agents))
            // `repo=owner/name`: the project whose GitHub remote it is, unless the link named a project itself.
            if link.project == nil, let repository = link.repository {
                Task {
                    if let folder = await projectFolder(repository: repository) { PromptLinkInbox.shared.requestProject(folder) }
                }
            }
            return
        }
        if let link = SessionLink.parse(url), let id = UUID(uuidString: link.id), workspace.run(id) != nil {
            openWorkspace(run: id)
        }
    }

    /// `pr=owner/name/123`: the session linked to that pull request opens with the words in its composer; without one,
    /// the new-session composer asks before it checks the branch out in a worktree of its own (`pendingCheckout`).
    private func openPullRequestLink(_ link: PromptLink, _ pull: PromptLink.PullRequest) {
        let order = workspace.runs.filter { !$0.archived }.sorted { $0.updatedAt > $1.updatedAt }.map(\.id)
        if let id = PromptLinkSessions.linked(pull.repository, pull.number, links: PullRequestSync.shared.links, order: order),
           let run = workspace.run(id) {
            if !link.text.isEmpty {
                ComposerInbox.shared.add(link.text, to: SessionContextTarget(run: id, directory: run.workingDirectory))
            }
            openWorkspace(run: id)
            return
        }
        PromptLinkInbox.shared.pendingCheckout = link
        viewModel.selectedAgentID = "new"
        viewModel.show(.panel(.agents))
    }
}
