import WebKit

extension WKWebView {
    /// Switches the window to the agent the page of a main-frame navigation is asked for with (see `WebSignInAgent`).
    /// True when it changed: the navigation is then cancelled and the page asked for again, so it already gets the
    /// new agent.
    @MainActor
    func presentsItself(for navigationAction: WKNavigationAction, otherwise: String?) -> Bool {
        guard navigationAction.targetFrame?.isMainFrame ?? true else { return false }
        let wanted = WebSignInAgent.agent(for: navigationAction.request.url, otherwise: otherwise) ?? ""
        guard (customUserAgent ?? "") != wanted else { return false }
        customUserAgent = wanted
        load(navigationAction.request)
        return true
    }
}

extension WKUserContentController {
    /// What every sign-in window needs on Google's sign-in pages besides its agent (see
    /// `WebSignInAgent.noPasskeysOnGoogle`).
    func addGoogleSignInHelp() {
        addUserScript(WKUserScript(source: WebSignInAgent.noPasskeysOnGoogle, injectionTime: .atDocumentStart,
                                   forMainFrameOnly: false))
    }
}
