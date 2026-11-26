import AppKit
import AuthenticationServices

/// Passkeys in Nook's browser. WebKit handles them itself (iCloud Keychain, a phone nearby, a security key) once two
/// things hold: the build is signed with Apple's browser entitlement (`BrowserStore.hasPasskeyEntitlement`, see
/// docs/BROWSER-PASSKEYS.md), and you let Nook use your passkeys when macOS asks (System Settings › Privacy & Security
/// keeps the answer). Without either, pages do not see passkeys (`BrowserStore.hidePasskeys`), so sites offer a
/// password or a code instead of a prompt that can only fail.
@MainActor
final class BrowserPasskeys: ObservableObject {
    static let shared = BrowserPasskeys()

    enum State: Equatable {
        /// This build is not signed with Apple's browser entitlement.
        case needsEntitlement
        /// Signed with it; macOS has not asked you yet.
        case notAsked
        case allowed
        /// You (or a policy) said no in macOS.
        case denied
    }

    @Published private(set) var state: State
    private var asking = false
    /// Every new tab calls `ask`; only the first of a launch looks at macOS's answer.
    private var askedThisLaunch = false

    private init() { state = Self.current() }

    static func current() -> State {
        guard BrowserStore.hasPasskeyEntitlement else { return .needsEntitlement }
        switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
        case .authorized: return .allowed
        case .denied: return .denied
        case .notDetermined: return .notAsked
        @unknown default: return .notAsked
        }
    }

    /// Whether pages may see passkeys: the build has the entitlement and macOS did not refuse. Not yet asked counts as
    /// usable, so the first site that wants a passkey gets macOS's question instead of a page without passkeys.
    static var usable: Bool {
        switch current() {
        case .needsEntitlement, .denied: return false
        case .notAsked, .allowed: return true
        }
    }

    func refresh() {
        let now = Self.current()
        if now != state { state = now }
    }

    /// Puts macOS's question (may Nook use your passkeys?) once; macOS remembers the answer.
    func ask() {
        guard !askedThisLaunch else { return }
        askedThisLaunch = true
        askNow()
    }

    /// The same question from the button in Settings › Browser.
    func askNow() {
        refresh()
        guard state == .notAsked, !asking else { return }
        asking = true
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
            Task { @MainActor in
                let passkeys = BrowserPasskeys.shared
                passkeys.asking = false
                passkeys.refresh()
            }
        }
    }

    /// Privacy & Security in System Settings, where the answer can be changed.
    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(url)
        }
    }
}
