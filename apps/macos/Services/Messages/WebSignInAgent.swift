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

    /// Runs on Google's sign-in pages before Google's own scripts. macOS lets an app's own browser use passkeys only for
    /// the app's own sites, so Google's passkey sign-in (also with a phone nearby, "make sure Bluetooth is on") always
    /// fails in it. The page still sees passkeys as a browser has them (Google turns away a browser without them as
    /// not secure, and a changed function that does not read as the browser's own), but hears there is no passkey on
    /// this Mac, and a passkey request is answered at once as if you cancelled it, so "Try another way" leads to your
    /// password or a prompt on your phone. Every change is a Proxy, which reads as the browser's own function.
    static let googlePasskeys = """
    (() => {
      if (!/(^|\\.)accounts\\.google\\.com$/i.test(location.hostname)) return;
      const wrap = (owner, name, apply) => {
        try {
          const original = owner && owner[name];
          if (typeof original !== 'function') return;
          const descriptor = Object.getOwnPropertyDescriptor(owner, name) || { configurable: true, enumerable: false, writable: true };
          Object.defineProperty(owner, name, { ...descriptor, value: new Proxy(original, { apply }) });
        } catch (error) {}
      };
      const none = () => Promise.resolve(false);
      const key = window.PublicKeyCredential;
      wrap(key, 'isUserVerifyingPlatformAuthenticatorAvailable', none);
      wrap(key, 'isConditionalMediationAvailable', none);
      const refuse = () => Promise.reject(new DOMException('The operation either timed out or was not allowed.', 'NotAllowedError'));
      const container = window.CredentialsContainer && CredentialsContainer.prototype;
      for (const name of ['get', 'create']) {
        wrap(container, name, (target, self, args) => (args[0] && args[0].publicKey ? refuse() : Reflect.apply(target, self, args)));
      }
    })();
    """

    /// Google's sign-in pages, where Nook's own page scripts stay out (see `googlePasskeys`): a script of a sign-in
    /// window that changes the page starts with this and returns on them.
    static let skipOnGoogle = "if (/(^|\\.)accounts\\.google\\.com$/i.test(location.hostname)) return;"
}
