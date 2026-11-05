import Foundation
import WebKit

/// Sign-ins a project keeps (Settings › Workspace, per project). By default every browser shares one store that nothing
/// of is written to disk. A project that turns this on gets a store of its own on disk: another project, Nook's own
/// browser and agents elsewhere never reach its sign-ins. The agents of that project do, through the pages they open.
@MainActor
enum BrowserProfiles {
    /// The browser of no project that keeps sign-ins: nothing is written to disk.
    static let ephemeral = WKWebsiteDataStore.nonPersistent()
    /// The project a browser belongs to, and whether that project keeps sign-ins. Set by the app.
    static var project: (BrowserSession.Key) -> String? = { _ in nil }
    static var keepsSignIns: (String) -> Bool = { _ in false }

    private static let idsKey = "browser.profileIDs"
    private static var stores: [UUID: WKWebsiteDataStore] = [:]

    static func dataStore(for key: BrowserSession.Key?) -> WKWebsiteDataStore {
        guard let key, let project = project(key), keepsSignIns(project) else { return ephemeral }
        return store(id(of: project))
    }

    /// The project stopped keeping sign-ins: what it kept goes. Browsers open now keep their pages until they close.
    static func forget(project: String) {
        let project = WorkspacePathPolicy.normalize(project)
        var ids = savedIDs
        guard let saved = ids[project], let id = UUID(uuidString: saved) else { return }
        ids[project] = nil
        UserDefaults.standard.set(ids, forKey: idsKey)
        store(id).removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    private static var savedIDs: [String: String] {
        UserDefaults.standard.dictionary(forKey: idsKey) as? [String: String] ?? [:]
    }

    private static func id(of project: String) -> UUID {
        let project = WorkspacePathPolicy.normalize(project)
        var ids = savedIDs
        if let saved = ids[project].flatMap(UUID.init(uuidString:)) { return saved }
        let made = UUID()
        ids[project] = made.uuidString
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
