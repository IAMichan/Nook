import AppKit
import UniformTypeIdentifiers

/// Nook as the Mac's default web browser (Settings › Browser). macOS asks you itself whether to switch ("Use Nook" or
/// keep the browser you have); Nook only starts that question. The browser that was the default before is remembered
/// (`PreviousBrowser`), so "Open in …" and links Nook does not open itself still reach it.
@MainActor
enum DefaultBrowser {
    private static var probe: URL { URL(string: "https://example.com")! }

    private static var ownBundleID: String { Bundle.main.bundleIdentifier ?? "" }

    /// The app macOS opens web links with now.
    static var currentHandler: URL? { NSWorkspace.shared.urlForApplication(toOpen: probe) }

    /// Whether web links open in this Nook now. Asked of LaunchServices at most every few seconds: the browser's toolbar
    /// reads it while it draws.
    static var isNook: Bool {
        if let cached, Date().timeIntervalSince(cached.at) < 5 { return cached.value }
        let value = currentHandler.flatMap { Bundle(url: $0)?.bundleIdentifier }?.lowercased() == ownBundleID.lowercased()
        cached = (value, Date())
        return value
    }
    private static var cached: (value: Bool, at: Date)?

    /// Forget the answer: after a switch, or when Settings › Browser shows.
    static func refresh() { cached = nil }

    /// The browser links go to when they leave Nook: the remembered one while Nook is the default, else the current one.
    static var outside: PreviousBrowser? {
        if isNook { return PreviousBrowser.load() }
        return currentHandler.flatMap(browser(at:))
    }

    /// Asks macOS to make Nook the default browser for web links and web pages. Remembers the browser you had first.
    static func makeNook(completion: @escaping (Error?) -> Void) {
        let remembered = PreviousBrowser.remembering(current: currentHandler.flatMap(browser(at:)), ownBundleID: ownBundleID,
                                                     stored: PreviousBrowser.load())
        remembered?.save()
        let app = Bundle.main.bundleURL
        cached = nil
        // http first: that is the one macOS asks about; https and the page types follow without a second question.
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            if let error {
                DispatchQueue.main.async { completion(error) }
                return
            }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { second in
                NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html) { _ in
                    DispatchQueue.main.async { completion(second) }
                }
            }
        }
    }

    /// Hands the web links back to the browser you had before Nook.
    static func restorePrevious(completion: @escaping (Error?) -> Void) {
        guard let previous = PreviousBrowser.load(),
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previous.bundleID) else {
            completion(nil)
            return
        }
        cached = nil
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { error in
            if let error {
                DispatchQueue.main.async { completion(error) }
                return
            }
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { second in
                NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html) { _ in
                    DispatchQueue.main.async { completion(second) }
                }
            }
        }
    }

    /// Opens a link outside Nook: in the browser you had before while Nook is the default (so it never comes back here),
    /// else as macOS opens it.
    static func openOutside(_ url: URL) {
        if isNook, let previous = PreviousBrowser.load(),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: previous.bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// "Open in Safari": the label of the button that sends a page out of Nook.
    static var openOutsideTitle: String {
        guard let name = outside?.name, !name.isEmpty else { return tr("browser.openExternal") }
        return tr("browserDefault.openIn", name)
    }

    private static func browser(at url: URL) -> PreviousBrowser? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return PreviousBrowser(bundleID: id, name: name)
    }
}
