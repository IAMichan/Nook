import Foundation
import AppKit

/// Voorkeuren voor de werkruimte, bewaard in UserDefaults zoals de rest van Nooks instellingen.
@MainActor
final class WorkspaceSettings: ObservableObject {
    static let shared = WorkspaceSettings()

    private let defaults = UserDefaults.standard

    @Published var defaultProvider: RunProvider {
        didSet { defaults.set(defaultProvider.rawValue, forKey: "ws.defaultProvider") }
    }
    /// Per agent het model dat Nook voorstelt (leeg = de standaard van de agent).
    @Published var defaultModels: [String: String] {
        didSet { defaults.set(defaultModels, forKey: "ws.defaultModels") }
    }
    @Published var defaultMode: ExecutionMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: "ws.defaultMode") }
    }
    @Published var defaultIsolation: IsolationMode {
        didSet { defaults.set(defaultIsolation.rawValue, forKey: "ws.defaultIsolation") }
    }
    @Published var defaultPermission: PermissionPolicy {
        didSet { defaults.set(defaultPermission.rawValue, forKey: "ws.defaultPermission") }
    }
    /// Waar nieuwe worktrees komen: <map>/<repository>/<branch>.
    @Published var worktreeRoot: String {
        didSet { defaults.set(worktreeRoot, forKey: "ws.worktreeRoot") }
    }
    /// Bundle-ID van je editor; leeg = de app die macOS voor mappen kiest (Finder).
    @Published var editorBundleID: String {
        didSet { defaults.set(editorBundleID, forKey: "ws.editor") }
    }
    @Published var terminalBundleID: String {
        didSet { defaults.set(terminalBundleID, forKey: "ws.terminal") }
    }
    /// Sessies die zo lang niet gebruikt zijn, gaan vanzelf naar het archief. 0 = nooit.
    @Published var autoArchiveDays: Int {
        didSet { defaults.set(autoArchiveDays, forKey: "ws.autoArchiveDays") }
    }
    /// Kosten tonen die de agent zelf meldt.
    @Published var showCost: Bool {
        didSet { defaults.set(showCost, forKey: "ws.showCost") }
    }
    @Published var lastProject: String {
        didSet { defaults.set(lastProject, forKey: "ws.lastProject") }
    }
    /// Projecten die je eerder koos, nieuwste eerst.
    @Published private(set) var recentProjects: [String]

    static var standardWorktreeRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/worktrees", isDirectory: true).path
    }

    private init() {
        defaultProvider = RunProvider(rawValue: defaults.string(forKey: "ws.defaultProvider") ?? "") ?? .claude
        defaultModels = (defaults.dictionary(forKey: "ws.defaultModels") as? [String: String]) ?? [:]
        defaultMode = ExecutionMode(rawValue: defaults.string(forKey: "ws.defaultMode") ?? "") ?? .agent
        defaultIsolation = IsolationMode(rawValue: defaults.string(forKey: "ws.defaultIsolation") ?? "") ?? .worktree
        defaultPermission = PermissionPolicy(rawValue: defaults.string(forKey: "ws.defaultPermission") ?? "") ?? .acceptEdits
        worktreeRoot = defaults.string(forKey: "ws.worktreeRoot").flatMap { $0.isEmpty ? nil : $0 } ?? Self.standardWorktreeRoot
        editorBundleID = defaults.string(forKey: "ws.editor") ?? ""
        terminalBundleID = defaults.string(forKey: "ws.terminal") ?? "com.apple.Terminal"
        autoArchiveDays = defaults.object(forKey: "ws.autoArchiveDays") as? Int ?? 0
        showCost = defaults.object(forKey: "ws.showCost") as? Bool ?? true
        lastProject = defaults.string(forKey: "ws.lastProject") ?? ""
        recentProjects = defaults.stringArray(forKey: "ws.recentProjects") ?? []
    }

    func rememberProject(_ path: String) {
        lastProject = path
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        recentProjects = Array(list.prefix(12))
        defaults.set(recentProjects, forKey: "ws.recentProjects")
    }

    func forgetProject(_ path: String) {
        recentProjects.removeAll { $0 == path }
        defaults.set(recentProjects, forKey: "ws.recentProjects")
        if lastProject == path { lastProject = "" }
    }

    func model(for provider: RunProvider) -> String { defaultModels[provider.rawValue] ?? "" }

    func setModel(_ model: String, for provider: RunProvider) { defaultModels[provider.rawValue] = model }

    /// Een veilige standaard die de agent ook echt ondersteunt.
    func permission(for provider: RunProvider) -> PermissionPolicy {
        provider.capabilities.policies.contains(defaultPermission) ? defaultPermission : .acceptEdits
    }

    // MARK: Apps

    struct AppChoice: Identifiable, Hashable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }

    static let editorCandidates: [AppChoice] = [
        AppChoice(bundleID: "com.microsoft.VSCode", name: "VS Code"),
        AppChoice(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        AppChoice(bundleID: "dev.zed.Zed", name: "Zed"),
        AppChoice(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
        AppChoice(bundleID: "com.sublimetext.4", name: "Sublime Text"),
        AppChoice(bundleID: "com.jetbrains.intellij", name: "IntelliJ IDEA"),
        AppChoice(bundleID: "com.google.android.studio", name: "Android Studio"),
        AppChoice(bundleID: "com.exafunction.windsurf", name: "Windsurf")
    ]

    static let terminalCandidates: [AppChoice] = [
        AppChoice(bundleID: "com.apple.Terminal", name: "Terminal"),
        AppChoice(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        AppChoice(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        AppChoice(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        AppChoice(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        AppChoice(bundleID: "com.github.wez.wezterm", name: "WezTerm")
    ]

    /// Alleen apps die op deze Mac staan.
    static func installed(_ candidates: [AppChoice]) -> [AppChoice] {
        candidates.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}
