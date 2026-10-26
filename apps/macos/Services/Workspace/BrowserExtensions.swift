import AppKit
import SwiftUI
import WebKit

/// Web extensions in Nook's browser and the artifact tab: a password manager or autofill extension (an unpacked folder
/// with a `manifest.json`) fills in sign-ins there like it does in a browser. WebKit runs them (macOS 15.4 and later);
/// Nook keeps the list of folders and gives each extension the access it asks for, on every site.
@MainActor
final class BrowserExtensions: ObservableObject {
    static let shared = BrowserExtensions()

    /// One folder in the list and what became of it.
    struct Entry: Identifiable, Equatable {
        let path: String
        var name: String
        /// Why it is not running, if it is not.
        var problem: String?
        var id: String { path }
    }

    @Published private(set) var entries: [Entry] = []
    private static let defaultsKey = "nook.browser.extensionFolders"
    /// Whether this macOS can run web extensions.
    static var isSupported: Bool {
        if #available(macOS 15.4, *) { return true }
        return false
    }

    private var storedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    /// The controller every browser web view is made with, started on first use with the folders saved before. It is
    /// kept as `AnyObject` so the property exists on macOS before 15.4.
    private var storedController: AnyObject?
    private var contexts: [String: AnyObject] = [:]

    private init() {}

    /// Gives a web view's configuration the extensions, before the web view is made.
    func attach(to configuration: WKWebViewConfiguration) {
        guard #available(macOS 15.4, *) else { return }
        configuration.webExtensionController = controller
    }

    @available(macOS 15.4, *)
    private var controller: WKWebExtensionController {
        if let storedController = storedController as? WKWebExtensionController { return storedController }
        let made = WKWebExtensionController(configuration: .default())
        storedController = made
        let paths = storedPaths
        entries = paths.map { Entry(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent, problem: nil) }
        Task { for path in paths { await load(path) } }
        return made
    }

    /// Adds the extension in `url` (a folder with a manifest) and starts it.
    func add(_ url: URL) async {
        guard #available(macOS 15.4, *) else { return }
        _ = controller
        let path = url.path
        guard !storedPaths.contains(path) else { return }
        storedPaths.append(path)
        entries.append(Entry(path: path, name: url.lastPathComponent, problem: nil))
        await load(path)
    }

    /// Stops the extension and forgets its folder.
    func remove(_ path: String) {
        storedPaths.removeAll { $0 == path }
        entries.removeAll { $0.path == path }
        if #available(macOS 15.4, *), let controller = storedController as? WKWebExtensionController,
           let context = contexts.removeValue(forKey: path) as? WKWebExtensionContext {
            try? controller.unload(context)
        }
    }

    @available(macOS 15.4, *)
    private func load(_ path: String) async {
        guard let controller = storedController as? WKWebExtensionController else { return }
        do {
            let loaded = try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: path, isDirectory: true))
            let context = WKWebExtensionContext(for: loaded)
            // The extension is one you added yourself: what its manifest asks for is granted, on every site.
            for permission in loaded.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
            for pattern in loaded.requestedPermissionMatchPatterns.union(loaded.optionalPermissionMatchPatterns) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            try controller.load(context)
            contexts[path] = context
            update(path, name: loaded.displayName, problem: nil)
        } catch {
            update(path, name: nil, problem: error.localizedDescription)
        }
    }

    private func update(_ path: String, name: String?, problem: String?) {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return }
        if let name { entries[index].name = name }
        entries[index].problem = problem
    }
}
