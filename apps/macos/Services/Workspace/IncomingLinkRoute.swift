import Foundation

/// Where a web link opens that another app handed to Nook while Nook is the default browser (Settings › Browser).
enum IncomingLinkTarget: String, CaseIterable, Identifiable, Sendable {
    /// In the browser of the session on screen, as a new tab in its side panel; without a session on screen, as below.
    case session
    /// In Nook's own browser, full size in the main window (Agents › Browser), so you can ask about the page right away.
    case nookBrowser

    var id: String { rawValue }
    static let defaultsKey = "nook.browser.incomingLinks"

    static func current(defaults: UserDefaults = .standard) -> IncomingLinkTarget {
        defaults.string(forKey: defaultsKey).flatMap(IncomingLinkTarget.init(rawValue:)) ?? .session
    }
}

/// The decision for one link that macOS handed to Nook (`application(_:open:)`): kept apart from AppKit so it is tested.
enum IncomingLinkRoute: Equatable, Sendable {
    /// Nook's own `nook://` links (a prompt, a session): handled as before, never as a web page.
    case nookLink
    /// A new tab in the browser the session on screen shows in its panel now.
    case sessionPanel
    /// The session on screen's browser, brought up in its side panel.
    case sessionBrowser
    /// Nook's own browser, full size in the main window.
    case nookBrowser
    /// Not something Nook's browser opens (another scheme, a file that is no web page): to the browser you had before.
    case previousBrowser

    /// File types macOS hands over as web documents (`CFBundleDocumentTypes` in project.yml).
    static let documentExtensions: Set<String> = ["html", "htm", "xhtml", "shtml"]

    /// - Parameters:
    ///   - panelShowsBrowser: a session on screen shows its browser in a panel now.
    ///   - sessionOnScreen: a session is open in the notch or the main window.
    static func decide(_ url: URL, target: IncomingLinkTarget, panelShowsBrowser: Bool, sessionOnScreen: Bool) -> IncomingLinkRoute {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "nook" { return .nookLink }
        let web = scheme == "http" || scheme == "https"
        let document = url.isFileURL && documentExtensions.contains(url.pathExtension.lowercased())
        guard web || document else { return .previousBrowser }
        // The browser in sight wins: a link you open while you look at a session's page joins it, whatever the setting.
        if panelShowsBrowser { return .sessionPanel }
        switch target {
        case .session: return sessionOnScreen ? .sessionBrowser : .nookBrowser
        case .nookBrowser: return .nookBrowser
        }
    }
}

/// The browser that was the default before Nook became it: links Nook does not open itself, and "Open in …" in its
/// browser, go there instead of coming back to Nook.
struct PreviousBrowser: Equatable, Sendable {
    static let defaultsKey = "nook.browser.previousDefault"

    var bundleID: String
    var name: String

    /// The browser to remember when Nook becomes the default: the current one, unless that is Nook itself (asked twice).
    static func remembering(current: PreviousBrowser?, ownBundleID: String, stored: PreviousBrowser?) -> PreviousBrowser? {
        guard let current, current.bundleID.lowercased() != ownBundleID.lowercased() else { return stored }
        return current
    }

    static func load(_ defaults: UserDefaults = .standard) -> PreviousBrowser? {
        guard let stored = defaults.dictionary(forKey: defaultsKey) as? [String: String],
              let bundleID = stored["bundleID"], !bundleID.isEmpty else { return nil }
        return PreviousBrowser(bundleID: bundleID, name: stored["name"] ?? bundleID)
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(["bundleID": bundleID, "name": name], forKey: Self.defaultsKey)
    }
}
