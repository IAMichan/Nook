import Foundation
import AppKit

/// Preferences for the workspace, stored in UserDefaults like the rest of Nook's settings.
@MainActor
final class WorkspaceSettings: ObservableObject {
    static let shared = WorkspaceSettings()

    private let defaults = UserDefaults.standard

    @Published var defaultProvider: RunProvider {
        didSet { defaults.set(defaultProvider.rawValue, forKey: "ws.defaultProvider") }
    }
    /// Suggested model per agent (empty = agent default).
    @Published var defaultModels: [String: String] {
        didSet { defaults.set(defaultModels, forKey: "ws.defaultModels") }
    }
    /// The account last chosen per agent, so a new session starts with it again.
    @Published var defaultProfiles: [String: String] {
        didSet { defaults.set(defaultProfiles, forKey: "ws.defaultProfiles") }
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
    /// Location where new worktrees are created: <folder>/<repository>/<branch>.
    @Published var worktreeRoot: String {
        didSet { defaults.set(worktreeRoot, forKey: "ws.worktreeRoot") }
    }
    /// Prefix of the branches Nook creates ("nook" → "nook/fix-login-3fa2"). Read by `WorktreeNaming.branchPrefix`.
    @Published var branchPrefix: String {
        didSet { defaults.set(branchPrefix, forKey: WorktreeNaming.branchPrefixKey) }
    }
    /// Bundle ID of your editor; empty = app macOS chooses for folders (Finder).
    @Published var editorBundleID: String {
        didSet { defaults.set(editorBundleID, forKey: "ws.editor") }
    }
    @Published var terminalBundleID: String {
        didSet { defaults.set(terminalBundleID, forKey: "ws.terminal") }
    }
    /// Sessions unused for this duration are automatically archived. 0 = never.
    @Published var autoArchiveDays: Int {
        didSet { defaults.set(autoArchiveDays, forKey: "ws.autoArchiveDays") }
    }
    /// Show costs reported by the agent itself.
    @Published var showCost: Bool {
        didSet { defaults.set(showCost, forKey: "ws.showCost") }
    }
    /// Codex runs over `codex app-server` (approvals, questions, steering, live reasoning); off: one `codex exec` per turn.
    @Published var codexAppServer: Bool {
        didSet { defaults.set(codexAppServer, forKey: "ws.codexAppServer") }
    }
    /// Coding agents may use Nook's terminal, browser and pull requests through the workspace bridge.
    @Published var agentTools: Bool {
        didSet { defaults.set(agentTools, forKey: "ws.agentTools") }
    }
    /// A new session gets a short title written by a small model in place of the first line of its task.
    @Published var autoTitles: Bool {
        didSet { defaults.set(autoTitles, forKey: "ws.autoTitles") }
    }
    /// A session stopped by a usage limit goes on by itself once the limit resets.
    @Published var autoResumeLimited: Bool {
        didSet { defaults.set(autoResumeLimited, forKey: "ws.autoResumeLimited") }
    }
    /// A session that a restart of Nook cut off gets "Continue where you left off." once.
    @Published var continueAfterRelaunch: Bool {
        didSet { defaults.set(continueAfterRelaunch, forKey: "ws.continueAfterRelaunch") }
    }
    /// A message typed while an agent works steers the turn (Cmd+Return queues it instead); off: it queues (Cmd+Return steers).
    /// Configurable in Settings.
    @Published var steerByDefault: Bool {
        didSet { defaults.set(steerByDefault, forKey: "ws.steerByDefault") }
    }
    /// Scheduled tasks (interval, fixed time, webhook) may start sessions. Off by default; nothing runs on its own until you turn it on.
    @Published var scheduledTasksEnabled: Bool {
        didSet { defaults.set(scheduledTasksEnabled, forKey: "ws.scheduledTasksEnabled") }
    }
    /// Local port for webhook-triggered tasks (127.0.0.1 only); 0 = no listener.
    @Published var scheduledWebhookPort: Int {
        didSet { defaults.set(scheduledWebhookPort, forKey: "ws.scheduledWebhookPort") }
    }
    @Published var lastProject: String {
        didSet { defaults.set(lastProject, forKey: "ws.lastProject") }
    }
    /// Previously selected projects, newest first.
    @Published private(set) var recentProjects: [String]

    static var standardWorktreeRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/worktrees", isDirectory: true).path
    }

    private init() {
        defaultProvider = RunProvider(rawValue: defaults.string(forKey: "ws.defaultProvider") ?? "") ?? .claude
        defaultModels = (defaults.dictionary(forKey: "ws.defaultModels") as? [String: String]) ?? [:]
        defaultProfiles = (defaults.dictionary(forKey: "ws.defaultProfiles") as? [String: String]) ?? [:]
        defaultMode = ExecutionMode(rawValue: defaults.string(forKey: "ws.defaultMode") ?? "") ?? .agent
        defaultIsolation = IsolationMode(rawValue: defaults.string(forKey: "ws.defaultIsolation") ?? "") ?? .worktree
        defaultPermission = PermissionPolicy(rawValue: defaults.string(forKey: "ws.defaultPermission") ?? "") ?? .acceptEdits
        worktreeRoot = defaults.string(forKey: "ws.worktreeRoot").flatMap { $0.isEmpty ? nil : $0 } ?? Self.standardWorktreeRoot
        branchPrefix = defaults.string(forKey: WorktreeNaming.branchPrefixKey) ?? WorktreeNaming.defaultBranchPrefix
        editorBundleID = defaults.string(forKey: "ws.editor") ?? ""
        terminalBundleID = defaults.string(forKey: "ws.terminal") ?? Self.builtInTerminal
        autoArchiveDays = defaults.object(forKey: "ws.autoArchiveDays") as? Int ?? 0
        showCost = defaults.object(forKey: "ws.showCost") as? Bool ?? true
        agentTools = defaults.object(forKey: "ws.agentTools") as? Bool ?? true
        codexAppServer = defaults.object(forKey: "ws.codexAppServer") as? Bool ?? true
        autoTitles = defaults.object(forKey: "ws.autoTitles") as? Bool ?? true
        autoResumeLimited = defaults.object(forKey: "ws.autoResumeLimited") as? Bool ?? false
        continueAfterRelaunch = defaults.object(forKey: "ws.continueAfterRelaunch") as? Bool ?? false
        steerByDefault = defaults.object(forKey: "ws.steerByDefault") as? Bool ?? true
        scheduledTasksEnabled = defaults.object(forKey: "ws.scheduledTasksEnabled") as? Bool ?? false
        scheduledWebhookPort = defaults.object(forKey: "ws.scheduledWebhookPort") as? Int ?? 0
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

    func profile(for provider: RunProvider) -> String? { defaultProfiles[provider.rawValue] }

    func setProfile(_ profileID: String, for provider: RunProvider) { defaultProfiles[provider.rawValue] = profileID }

    /// A safe default that the agent actually supports.
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

    /// The terminal inside Nook's main window (Agents › Terminals).
    nonisolated static let builtInTerminal = "nook.builtin"

    static let terminalCandidates: [AppChoice] = [
        AppChoice(bundleID: builtInTerminal, name: "Nook"),
        AppChoice(bundleID: "com.apple.Terminal", name: "Terminal"),
        AppChoice(bundleID: "com.googlecode.iterm2", name: "iTerm"),
        AppChoice(bundleID: "com.mitchellh.ghostty", name: "Ghostty"),
        AppChoice(bundleID: "dev.warp.Warp-Stable", name: "Warp"),
        AppChoice(bundleID: "net.kovidgoyal.kitty", name: "kitty"),
        AppChoice(bundleID: "com.github.wez.wezterm", name: "WezTerm")
    ]

    /// Only apps installed on this Mac.
    static func installed(_ candidates: [AppChoice]) -> [AppChoice] {
        candidates.filter { $0.bundleID == builtInTerminal || NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}
