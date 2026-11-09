import Foundation
import WebKit

/// Where a browser keeps its sign-ins (`BrowserSignInPolicy`, Settings › Browser for all, Settings › Projects per project).
/// Each project has a store of its own on disk, and so does Nook's own browser: another project, Nook's own browser and
/// agents elsewhere never reach its sign-ins. The agents of a project do, through the pages they open.
///
/// - Keep: the store stays between launches.
/// - Ask: the browser writes to its store too, so the sign-in you make before you answer survives a "Keep". Until you
///   answer Keep, `sweep` empties it at the next launch, and answering "Don't keep" empties it at once.
/// - Forget: one shared store that nothing is written to disk of.
@MainActor
enum BrowserProfiles {
    /// The browser of no project that keeps sign-ins: nothing is written to disk.
    static let ephemeral = WKWebsiteDataStore.nonPersistent()
    /// The project a session's browser belongs to; nil for one that has none on this Mac (a remote session). Set by the app.
    static var project: (BrowserSession.Key) -> String? = { _ in nil }
    /// What a project (nil: Nook's own browser) does with sign-ins. Set by the app.
    static var policy: (String?) -> BrowserSignInPolicy = { _ in .forget }
    /// Your answer to "Keep sign-ins?" from a browser: stored where that browser's "ask" came from. Set by the app.
    static var answer: (BrowserSession.Key?, Bool) -> Void = { _, _ in }

    private static let idsKey = "browser.profileIDs"
    /// The owner Nook's own browser keeps its store under, beside the project paths.
    private static let nookOwner = "nook:browser"
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    /// The owner of a browser's sign-ins: its project, Nook's own (no session), or none (a session on another machine).
    private enum Owner {
        case nook
        case project(String)
        case none
    }

    private static func owner(of key: BrowserSession.Key?) -> Owner {
        guard let key else { return .nook }
        return project(key).map(Owner.project) ?? .none
    }

    /// What the browser of this session (nil: Nook's own) does with sign-ins.
    static func policy(for key: BrowserSession.Key?) -> BrowserSignInPolicy {
        switch owner(of: key) {
        case .nook: return policy(nil)
        case .project(let path): return policy(path)
        case .none: return .forget
        }
    }

    static func dataStore(for key: BrowserSession.Key?) -> WKWebsiteDataStore {
        let name: String
        switch owner(of: key) {
        case .nook: name = nookOwner
        case .project(let path): name = path
        case .none: return ephemeral
        }
        return policy(for: key) == .forget ? ephemeral : store(id(of: name))
    }

    /// A project (nil: Nook's own browser) stopped keeping sign-ins: what it kept goes. Its id stays known: a browser
    /// still open writes on until it closes, and `sweep` clears that at the next launch.
    static func forget(project: String?) {
        let name = project.map(WorkspacePathPolicy.normalize) ?? nookOwner
        guard let saved = savedIDs[name], let id = UUID(uuidString: saved) else { return }
        store(id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// At launch, and after the policy changed: empties every store whose owner does not keep sign-ins (also those still
    /// asking: you never said to keep them).
    static func sweep() {
        for name in savedIDs.keys {
            let project = name == nookOwner ? nil : name
            if policy(project) != .keep { forget(project: project) }
        }
    }

    private static var savedIDs: [String: String] {
        UserDefaults.standard.dictionary(forKey: idsKey) as? [String: String] ?? [:]
    }

    private static func id(of owner: String) -> UUID {
        let owner = owner == nookOwner ? owner : WorkspacePathPolicy.normalize(owner)
        var ids = savedIDs
        if let saved = ids[owner].flatMap(UUID.init(uuidString:)) { return saved }
        let made = UUID()
        ids[owner] = made.uuidString
        UserDefaults.standard.set(ids, forKey: idsKey)
        return made
    }

    private static func store(_ id: UUID) -> WKWebsiteDataStore {
        if let known = stores[id] { return known }
        let made = WKWebsiteDataStore(forIdentifier: id)
        stores[id] = made
        return made
    }
}

/// Notices a sign-in on a page: a form sent, Enter pressed or a button clicked while a password field holds text. Runs in
/// every frame, in a world of its own, so the page's scripts neither see nor stop it. Reports the site once per page.
enum BrowserSignInScript {
    static let handlerName = "nookSignIn"

    static let source = """
    (function () {
      var sent = false;
      function filled(root) {
        var fields = (root && root.querySelectorAll ? root : document).querySelectorAll('input[type=password]');
        for (var i = 0; i < fields.length; i++) { if (fields[i].value) { return true; } }
        return false;
      }
      function report() {
        if (sent) { return; }
        sent = true;
        try { window.webkit.messageHandlers.\(handlerName).postMessage(location.hostname || ''); } catch (e) {}
      }
      document.addEventListener('submit', function (e) { if (filled(e.target)) { report(); } }, true);
      document.addEventListener('keydown', function (e) {
        var t = e.target;
        if (e.key === 'Enter' && t && t.type === 'password' && t.value) { report(); }
      }, true);
      document.addEventListener('click', function (e) {
        var t = e.target;
        var button = t && t.closest ? t.closest('button, input[type=submit], [role=button]') : null;
        if (button && filled(button.form || document)) { report(); }
      }, true);
    })();
    """
}
