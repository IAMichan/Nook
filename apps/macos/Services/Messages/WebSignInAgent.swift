import Foundation

/// How Nook's sign-in windows present themselves. Google turns away sign-ins in an app's own browser ("This browser or
/// app may not be secure"), also when it calls itself Safari, but lets a desktop Firefox in; so on Google's sign-in
/// pages (signing in with Google, or a school or work account that signs in through Google) the window calls itself
/// Firefox, and everywhere else what it called itself before. Foundation only, so it can be tested anywhere.
enum WebSignInAgent {
    /// Google's sign-in pages.
    static func isGoogleSignIn(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com") || host == "accounts.youtube.com"
    }

    /// A desktop Firefox on this Mac, of about the current version (one comes out every four weeks), so Google does not
    /// take it for an outdated browser.
    static func firefox(now: Date = Date()) -> String {
        let first = Date(timeIntervalSince1970: 1_741_046_400) // Firefox 136, 4 March 2025
        let version = 136 + max(0, Int(now.timeIntervalSince(first) / (28 * 86_400)))
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:\(version).0) Gecko/20100101 Firefox/\(version).0"
    }

    /// The agent a page in the main frame is asked for with: Firefox on Google's sign-in pages, `otherwise` elsewhere
    /// (nil: the web view's own).
    static func agent(for url: URL?, otherwise: String?, now: Date = Date()) -> String? {
        isGoogleSignIn(url) ? firefox(now: now) : otherwise
    }
}
