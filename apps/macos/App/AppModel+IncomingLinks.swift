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
            PromptLinkInbox.shared.pending = link
            viewModel.selectedAgentID = "new"
            viewModel.show(.panel(.agents))
            return
        }
        if let link = SessionLink.parse(url), let id = UUID(uuidString: link.id), workspace.run(id) != nil {
            openWorkspace(run: id)
        }
    }
}
