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
    /// Reasoning effort per agent for new sessions (absent = agent default).
    @Published var defaultEfforts: [String: String] {
        didSet { defaults.set(defaultEfforts, forKey: "ws.defaultEfforts") }
    }
    /// The account last chosen per agent, so a new session starts with it again.
    @Published var defaultProfiles: [String: String] {
        didSet { defaults.set(defaultProfiles, forKey: "ws.defaultProfiles") }
    }
    /// Favorite models per agent: listed first in the model menus.
    @Published var favoriteModels: [String: [String]] {
        didSet { defaults.set(favoriteModels, forKey: "ws.favoriteModels") }
    }
    /// The models "Auto" may pick per agent (see `AutoModel`); none: every current model the agent offers.
    @Published var autoModels: [String: [String]] {
        didSet { defaults.set(autoModels, forKey: "ws.autoModels") }
    }
    /// The agents (`RunProvider.rawValue`) and accounts (profile ids) "Auto" leaves alone; none: every connected one.
    @Published var autoAgentsOff: [String] {
        didSet { defaults.set(autoAgentsOff, forKey: "ws.autoAgentsOff") }
    }
    @Published var autoAccountsOff: [String] {
        didSet { defaults.set(autoAccountsOff, forKey: "ws.autoAccountsOff") }
    }
    /// Model ids you typed yourself per agent, newest first (see `ModelPreferences`).
    @Published var customModels: [String: [String]] {
        didSet { defaults.set(customModels, forKey: "ws.customModels") }
    }
    /// Nook may fetch a fresh model list from its repository (new models, which agent update they need). Off: the list
    /// that came with the app is used and nothing goes online for it.
    @Published var onlineModelList: Bool {
        didSet { defaults.set(onlineModelList, forKey: "ws.onlineModelList") }
    }
    @Published var defaultMode: ExecutionMode {
        didSet { defaults.set(defaultMode.rawValue, forKey: "ws.defaultMode") }
    }
    /// What browsers do with sign-ins in every project that does not set its own, and in Nook's own browser.
    @Published var browserSignInPolicy: BrowserSignInPolicy {
        didSet { defaults.set(browserSignInPolicy.stored, forKey: "ws.browserSignIns") }
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
    /// New worktrees are cloned (APFS copy-on-write) from a cached checkout of the repository (`WorktreeCheckoutCache`).
    /// Off by default; switching it off deletes the cache.
    @Published var fastWorktrees: Bool {
        didSet {
            defaults.set(fastWorktrees, forKey: "ws.fastWorktrees")
            if oldValue, !fastWorktrees { WorktreeCheckoutCache.clear() }
        }
    }
    /// How new worktrees check out submodules, for every project that does not set its own.
    @Published var worktreeSubmodules: SubmoduleMode {
        didSet { defaults.set(worktreeSubmodules.rawValue, forKey: "ws.worktreeSubmodules") }
    }
    /// Fast-forward each project's default branch in its main checkout when it is clean (projects can override it).
    @Published var autoPullDefaultBranch: Bool {
        didSet { defaults.set(autoPullDefaultBranch, forKey: "ws.autoPullDefaultBranch") }
    }
    /// Clones go into `<host>/<owner>/<repo>` under the folder you clone into, like ghq lays them out.
    @Published var cloneHostLayout: Bool {
        didSet { defaults.set(cloneHostLayout, forKey: "ws.cloneHostLayout") }
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
    /// Nook removes a session's worktree by itself once its pull request is merged, or this many days after the session
    /// settled (0 = never). Off by default; a worktree in use or with uncommitted changes always stays (`WorktreeCleanup`).
    @Published var worktreeCleanupOnMerge: Bool {
        didSet { defaults.set(worktreeCleanupOnMerge, forKey: "ws.worktreeCleanupOnMerge") }
    }
    @Published var worktreeCleanupDays: Int {
        didSet { defaults.set(worktreeCleanupDays, forKey: "ws.worktreeCleanupDays") }
    }
    /// Remove builds agents left in temporary folders and DerivedData of removed worktrees (`BuildLeftovers`).
    @Published var buildLeftoverCleanup: Bool {
        didSet { defaults.set(buildLeftoverCleanup, forKey: "ws.buildLeftoverCleanup") }
    }
    @Published var worktreeCleanupInactiveDays: Int {
        didSet { defaults.set(worktreeCleanupInactiveDays, forKey: "ws.worktreeCleanupInactiveDays") }
    }
    @Published var worktreeCleanupUnchanged: Bool {
        didSet { defaults.set(worktreeCleanupUnchanged, forKey: "ws.worktreeCleanupUnchanged") }
    }
    @Published var worktreeCleanupOnDelete: Bool {
        didSet { defaults.set(worktreeCleanupOnDelete, forKey: "ws.worktreeCleanupOnDelete") }
    }
    @Published var worktreeKeepWhen: WorktreeCleanup.KeepWhen {
        didSet { defaults.set(worktreeKeepWhen.rawValue, forKey: "ws.worktreeKeepWhen") }
    }
    var worktreeCleanupRules: WorktreeCleanup.Rules {
        WorktreeCleanup.Rules(onMergedPullRequest: worktreeCleanupOnMerge, daysAfterSettled: worktreeCleanupDays,
                              daysInactive: worktreeCleanupInactiveDays, onUnchanged: worktreeCleanupUnchanged,
                              onDeletedSession: worktreeCleanupOnDelete, keepWhen: worktreeKeepWhen)
    }
    /// The rules for the worktrees of one repository: none when the project switched cleanup off.
    func worktreeCleanupRules(for repo: String?) -> WorktreeCleanup.Rules {
        guard let repo, !sessionDefaults(for: repo).worktreeCleanup else { return worktreeCleanupRules }
        return WorktreeCleanup.Rules(keepWhen: worktreeKeepWhen)
    }
    /// How much of the agent's work a session's timeline shows, unless the session chose for itself (`TimelineDetail`).
    @Published var timelineDetail: TimelineDetail {
        didSet { defaults.set(timelineDetail.rawValue, forKey: "ws.timelineDetail") }
    }
    /// What a screen reader hears from the session on screen while VoiceOver runs (`AgentAnnouncements`).
    @Published var screenReaderAnnouncements: ScreenReaderAnnouncements {
        didSet { defaults.set(screenReaderAnnouncements.rawValue, forKey: "ws.screenReaderAnnouncements") }
    }
    /// Show costs reported by the agent itself.
    @Published var showCost: Bool {
        didSet { defaults.set(showCost, forKey: "ws.showCost") }
    }
    /// Codex runs over `codex app-server` (approvals, questions, steering, live reasoning); off: one `codex exec` per turn.
    @Published var codexAppServer: Bool {
        didSet { defaults.set(codexAppServer, forKey: "ws.codexAppServer") }
    }
    /// OpenCode 2.0.18 and newer runs over its own server (`opencode serve`: questions, deny with a reason, effort as the
    /// model's variant); off, or for an older OpenCode: over ACP.
    @Published var openCodeServer: Bool {
        didSet { defaults.set(openCodeServer, forKey: "ws.openCodeServer") }
    }
    /// Keeps what agents and Nook say to each other over stdio, per session (`ProviderTrafficLog`). Off by default.
    @Published var providerTrafficLog: Bool {
        didSet { defaults.set(providerTrafficLog, forKey: ProviderTrafficLog.enabledKey) }
    }
    /// Coding agents may use Nook's terminal, browser and pull requests through the workspace bridge.
    @Published var agentTools: Bool {
        didSet { defaults.set(agentTools, forKey: "ws.agentTools") }
    }
    /// Which groups of the bridge's tools each agent may use (`BridgeAccess`): Settings › Automation › Tools per agent.
    @Published var bridgeAccess: BridgeAccess {
        didSet { if bridgeAccess != oldValue { defaults.set(bridgeAccess.stored, forKey: "ws.bridgeDisabled") } }
    }
    /// How commit messages and pull requests are written (`CommitStyle`).
    @Published var commitStyle: CommitStyle {
        didSet { defaults.set(commitStyle.rawValue, forKey: CommitStyle.defaultsKey) }
    }
    /// Your own instructions for commit messages and pull requests, used with `CommitStyle.custom`.
    @Published var commitInstructions: String {
        didSet { defaults.set(commitInstructions, forKey: CommitStyle.instructionsKey) }
    }
    /// A new session gets a short title written by a small model in place of the first line of its task.
    @Published var autoTitles: Bool {
        didSet { defaults.set(autoTitles, forKey: "ws.autoTitles") }
    }
    /// Your own rules for written session titles ("start with the ticket number"), added to the title prompt. A project can
    /// set its own (`ProjectSettingKey.titleInstructions`).
    @Published var titleInstructions: String {
        didSet { defaults.set(titleInstructions, forKey: "ws.titleInstructions") }
    }
    /// Who writes each kind of text (`TextTask.rawValue` → `TextGenerator.stored`); absent: the agent's CLI.
    @Published var textGenerators: [String: String] {
        didSet { defaults.set(textGenerators, forKey: "ws.textGenerators") }
    }
    /// After an agent's turn the empty composer shows the message you will likely send next (`NextPromptSuggestion`).
    /// Off by default: each suggestion is one more request.
    @Published var suggestNextPrompt: Bool {
        didSet { defaults.set(suggestNextPrompt, forKey: "ws.suggestNextPrompt") }
    }

    func textGenerator(for task: TextTask) -> TextGenerator { TextGenerator(stored: textGenerators[task.rawValue]) }

    func setTextGenerator(_ generator: TextGenerator, for task: TextTask) {
        let stored: String? = generator == .agent ? nil : generator.stored
        guard textGenerators[task.rawValue] != stored else { return }
        textGenerators[task.rawValue] = stored
    }
    /// At most this many sessions work at once; a turn past it waits for a free place (`SessionCapacity`). 0: no limit.
    @Published var maxWorkingSessions: Int {
        didSet { defaults.set(maxWorkingSessions, forKey: "ws.maxWorkingSessions") }
    }
    /// Instructions every agent gets in every project, unless a project sets its own (`ProjectSettingKey.agentInstructions`).
    @Published var agentInstructions: String {
        didSet { defaults.set(agentInstructions, forKey: "ws.agentInstructions") }
    }
    /// A session stopped by a usage limit goes on by itself once the limit resets.
    @Published var autoResumeLimited: Bool {
        didSet { defaults.set(autoResumeLimited, forKey: "ws.autoResumeLimited") }
    }
    /// A long idle session is summarized shortly before its prompt cache expires, so your next message does not pay to
    /// write its whole history to the cache again (`IdleCompaction`). On by default.
    @Published var idleCompaction: Bool {
        didSet { defaults.set(idleCompaction, forKey: IdleCompaction.settingKey) }
    }
    /// A session whose context grows past this many tokens is summarized (/compact) when its turn ends; 0 is off
    /// (`SizeCompaction`).
    @Published var autoCompactTokens: Int {
        didSet { defaults.set(autoCompactTokens, forKey: SizeCompaction.settingKey) }
    }
    /// A session that a restart of Nook cut off gets "Continue where you left off." once.
    /// Agents go on while Nook is closed (`SessionKeeper`). Off by default.
    @Published var keepSessionsRunning: Bool {
        didSet { defaults.set(keepSessionsRunning, forKey: "ws.keepSessionsRunning") }
    }
    /// Nook in another app: cloud assistants reach Nook's tools through the relay (`RemoteMCPServer`). Off by default.
    @Published var remoteMCPEnabled: Bool {
        didSet { defaults.set(remoteMCPEnabled, forKey: "ws.remoteMCPEnabled") }
    }
    @Published var continueAfterRelaunch: Bool {
        didSet { defaults.set(continueAfterRelaunch, forKey: "ws.continueAfterRelaunch") }
    }
    /// A message typed while an agent works steers the turn (Cmd+Return queues it instead); off: it queues (Cmd+Return steers).
    /// Off by default: what you send during a turn waits in line, as you expect from a queue. Configurable in Settings.
    @Published var steerByDefault: Bool {
        didSet { defaults.set(steerByDefault, forKey: "ws.steerByDefault") }
    }
    /// A pull request a session opens (with the git button, pull_request_create or the agent's own `gh`) is watched from
    /// the start: CI, reviews and comments become news and wake the agent. On by default; off: you follow one yourself.
    @Published var watchNewPullRequests: Bool {
        didSet { defaults.set(watchNewPullRequests, forKey: "ws.watchNewPullRequests") }
    }
    /// Scheduled tasks (interval, fixed time, webhook) may start sessions. Off by default; nothing runs on its own until you turn it on.
    @Published var scheduledTasksEnabled: Bool {
        didSet { defaults.set(scheduledTasksEnabled, forKey: "ws.scheduledTasksEnabled") }
    }
    /// Local port for webhook-triggered tasks (127.0.0.1 only); 0 = no listener.
    /// Webhooks also reach this Mac from the internet, through the relay (`WebhookRelay`). Off by default.
    @Published var scheduledWebhooksPublic: Bool {
        didSet { defaults.set(scheduledWebhooksPublic, forKey: "ws.scheduledWebhooksPublic") }
    }
    @Published var scheduledWebhookPort: Int {
        didSet { defaults.set(scheduledWebhookPort, forKey: "ws.scheduledWebhookPort") }
    }
    @Published var lastProject: String {
        didSet { defaults.set(lastProject, forKey: "ws.lastProject") }
    }
    /// Favorite project folders: listed first in the project menu and never dropped.
    @Published private(set) var favoriteProjects: [String]
    /// Previously selected projects, newest first.
    @Published private(set) var recentProjects: [String]
    /// What project folders set for themselves on top of the defaults above (see `ProjectSettings`).
    @Published var projectOverrides: ProjectOverrides {
        didSet { defaults.setEncoded(projectOverrides, forKey: "ws.projectOverrides") }
    }
    /// What you last chose in the composer per folder (see `FolderChoicesStore`).
    @Published private(set) var folderChoices: FolderChoicesStore {
        didSet { defaults.setEncoded(folderChoices, forKey: "ws.folderChoices") }
    }

    static var standardWorktreeRoot: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".nook/worktrees", isDirectory: true).path
    }

    private init() {
        defaultProvider = RunProvider(rawValue: defaults.string(forKey: "ws.defaultProvider") ?? "") ?? .claude
        defaultModels = (defaults.dictionary(forKey: "ws.defaultModels") as? [String: String]) ?? [:]
        defaultProfiles = (defaults.dictionary(forKey: "ws.defaultProfiles") as? [String: String]) ?? [:]
        defaultEfforts = (defaults.dictionary(forKey: "ws.defaultEfforts") as? [String: String]) ?? [:]
        favoriteModels = (defaults.dictionary(forKey: "ws.favoriteModels") as? [String: [String]]) ?? [:]
        customModels = (defaults.dictionary(forKey: "ws.customModels") as? [String: [String]]) ?? [:]
        autoModels = (defaults.dictionary(forKey: "ws.autoModels") as? [String: [String]]) ?? [:]
        autoAgentsOff = defaults.stringArray(forKey: "ws.autoAgentsOff") ?? []
        autoAccountsOff = defaults.stringArray(forKey: "ws.autoAccountsOff") ?? []
        onlineModelList = defaults.object(forKey: "ws.onlineModelList") as? Bool ?? true
        defaultMode = ExecutionMode(rawValue: defaults.string(forKey: "ws.defaultMode") ?? "") ?? .agent
        defaultIsolation = IsolationMode(rawValue: defaults.string(forKey: "ws.defaultIsolation") ?? "") ?? .worktree
        browserSignInPolicy = BrowserSignInPolicy(stored: defaults.string(forKey: "ws.browserSignIns") ?? "") ?? .ask
        defaultPermission = PermissionPolicy(rawValue: defaults.string(forKey: "ws.defaultPermission") ?? "") ?? .acceptEdits
        worktreeRoot = defaults.string(forKey: "ws.worktreeRoot").flatMap { $0.isEmpty ? nil : $0 } ?? Self.standardWorktreeRoot
        branchPrefix = defaults.string(forKey: WorktreeNaming.branchPrefixKey) ?? WorktreeNaming.defaultBranchPrefix
        fastWorktrees = defaults.bool(forKey: "ws.fastWorktrees")
        worktreeSubmodules = SubmoduleMode(rawValue: defaults.string(forKey: "ws.worktreeSubmodules") ?? "") ?? .recursive
        autoPullDefaultBranch = defaults.bool(forKey: "ws.autoPullDefaultBranch")
        cloneHostLayout = defaults.bool(forKey: "ws.cloneHostLayout")
        editorBundleID = defaults.string(forKey: "ws.editor") ?? ""
        terminalBundleID = defaults.string(forKey: "ws.terminal") ?? Self.builtInTerminal
        autoArchiveDays = defaults.object(forKey: "ws.autoArchiveDays") as? Int ?? 0
        // On by default: after its pull request merged, and a week after its session settled. With every rule off,
        // 137 worktrees stayed for good and filled a 1 TB disk (2026-11-09). Nothing is lost: a worktree with local
        // changes or unpushed commits stays, the branch stays, and the session's next message makes the worktree again.
        // Builds left behind are swept separately (`buildLeftoverCleanup`), and Settings shows what is kept.
        worktreeCleanupOnMerge = defaults.object(forKey: "ws.worktreeCleanupOnMerge") as? Bool ?? true
        worktreeCleanupDays = defaults.object(forKey: "ws.worktreeCleanupDays") as? Int ?? 7
        worktreeCleanupInactiveDays = defaults.object(forKey: "ws.worktreeCleanupInactiveDays") as? Int ?? 0
        worktreeCleanupUnchanged = defaults.object(forKey: "ws.worktreeCleanupUnchanged") as? Bool ?? false
        worktreeCleanupOnDelete = defaults.object(forKey: "ws.worktreeCleanupOnDelete") as? Bool ?? false
        worktreeKeepWhen = WorktreeCleanup.KeepWhen(rawValue: defaults.string(forKey: "ws.worktreeKeepWhen") ?? "") ?? .uncommittedChanges
        buildLeftoverCleanup = defaults.object(forKey: "ws.buildLeftoverCleanup") as? Bool ?? true
        showCost = defaults.object(forKey: "ws.showCost") as? Bool ?? true
        timelineDetail = TimelineDetail(rawValue: defaults.string(forKey: "ws.timelineDetail") ?? "") ?? .everything
        screenReaderAnnouncements = ScreenReaderAnnouncements(rawValue: defaults.string(forKey: "ws.screenReaderAnnouncements") ?? "")
            ?? .replies
        agentTools = defaults.object(forKey: "ws.agentTools") as? Bool ?? true
        bridgeAccess = BridgeAccess(stored: defaults.dictionary(forKey: "ws.bridgeDisabled") as? [String: [String]] ?? [:])
        codexAppServer = defaults.object(forKey: "ws.codexAppServer") as? Bool ?? true
        openCodeServer = defaults.object(forKey: "ws.openCodeServer") as? Bool ?? true
        providerTrafficLog = defaults.bool(forKey: ProviderTrafficLog.enabledKey)
        autoTitles = defaults.object(forKey: "ws.autoTitles") as? Bool ?? true
        titleInstructions = defaults.string(forKey: "ws.titleInstructions") ?? ""
        textGenerators = defaults.dictionary(forKey: "ws.textGenerators") as? [String: String] ?? [:]
        suggestNextPrompt = defaults.bool(forKey: "ws.suggestNextPrompt")
        agentInstructions = defaults.string(forKey: "ws.agentInstructions") ?? ""
        maxWorkingSessions = defaults.object(forKey: "ws.maxWorkingSessions") as? Int ?? 0
        commitStyle = CommitStyle(rawValue: defaults.string(forKey: CommitStyle.defaultsKey) ?? "") ?? .standard
        commitInstructions = defaults.string(forKey: CommitStyle.instructionsKey) ?? ""
        autoResumeLimited = defaults.object(forKey: "ws.autoResumeLimited") as? Bool ?? false
        idleCompaction = defaults.object(forKey: IdleCompaction.settingKey) as? Bool ?? true
        autoCompactTokens = defaults.object(forKey: SizeCompaction.settingKey) as? Int ?? SizeCompaction.defaultTokens
        keepSessionsRunning = defaults.bool(forKey: "ws.keepSessionsRunning")
        remoteMCPEnabled = defaults.bool(forKey: "ws.remoteMCPEnabled")
        continueAfterRelaunch = defaults.object(forKey: "ws.continueAfterRelaunch") as? Bool ?? false
        steerByDefault = defaults.object(forKey: "ws.steerByDefault") as? Bool ?? false
        watchNewPullRequests = defaults.object(forKey: "ws.watchNewPullRequests") as? Bool ?? true
        scheduledTasksEnabled = defaults.object(forKey: "ws.scheduledTasksEnabled") as? Bool ?? false
        scheduledWebhooksPublic = defaults.bool(forKey: "ws.scheduledWebhooksPublic")
        scheduledWebhookPort = defaults.object(forKey: "ws.scheduledWebhookPort") as? Int ?? 0
        lastProject = defaults.string(forKey: "ws.lastProject") ?? ""
        favoriteProjects = defaults.stringArray(forKey: "ws.favoriteProjects") ?? []
        recentProjects = defaults.stringArray(forKey: "ws.recentProjects") ?? []
        // What cannot be read is kept aside first (`SafeStorage`), so the next change never loses it for good.
        projectOverrides = SafeStorage.decode(ProjectOverrides.Lossy.self, defaults: defaults, key: "ws.projectOverrides",
                                              skipped: { $0.skipped }).value?.overrides ?? ProjectOverrides()
        folderChoices = SafeStorage.decode(FolderChoicesStore.self, defaults: defaults, key: "ws.folderChoices").value
            ?? FolderChoicesStore()
    }

    func rememberProject(_ path: String) {
        lastProject = path
        var list = recentProjects.filter { $0 != path }
        list.insert(path, at: 0)
        recentProjects = Array(list.prefix(12))
        defaults.set(recentProjects, forKey: "ws.recentProjects")
    }

    func forgetProject(_ path: String) {
        let normalized = WorkspacePathPolicy.normalize(path)
        recentProjects.removeAll { $0 == path || WorkspacePathPolicy.normalize($0) == normalized }
        defaults.set(recentProjects, forKey: "ws.recentProjects")
        favoriteProjects.removeAll { $0 == path || WorkspacePathPolicy.normalize($0) == normalized }
        defaults.set(favoriteProjects, forKey: "ws.favoriteProjects")
        if lastProject == path || WorkspacePathPolicy.normalize(lastProject) == normalized { lastProject = "" }
        folderChoices.forget(path)
    }

    func isFavoriteProject(_ path: String) -> Bool {
        ProjectSettings.isFavorite(path, in: favoriteProjects, normalize: WorkspacePathPolicy.normalize)
    }

    func toggleFavoriteProject(_ path: String) {
        favoriteProjects = ProjectSettings.togglingFavorite(path, in: favoriteProjects, normalize: WorkspacePathPolicy.normalize)
        defaults.set(favoriteProjects, forKey: "ws.favoriteProjects")
    }

    func model(for provider: RunProvider) -> String { defaultModels[provider.rawValue] ?? "" }

    func setModel(_ model: String, for provider: RunProvider) { defaultModels[provider.rawValue] = model }

    func favoriteModels(for provider: RunProvider) -> [String] { favoriteModels(forKey: provider.rawValue) }

    func toggleFavoriteModel(_ model: String, for provider: RunProvider) { toggleFavoriteModel(model, forKey: provider.rawValue) }

    /// Favorites of another model picker than an agent's (Nook's own brain: "brain.<place>").
    func favoriteModels(forKey key: String) -> [String] { favoriteModels[key] ?? [] }

    func toggleFavoriteModel(_ model: String, forKey key: String) {
        favoriteModels[key] = ModelPreferences.toggling(model, in: favoriteModels(forKey: key))
    }

    func autoModels(for provider: RunProvider) -> [String] { autoModels[provider.rawValue] ?? [] }

    /// Allows or forbids `model` for "Auto". The first change starts from `all` (every current model), so unticking one
    /// keeps the others; allowing every current model again stores nothing, which also takes in models that come later,
    /// and unticking the last one stores `AutoModel.none`, which leaves the agent out of Auto.
    func toggleAutoModel(_ model: String, for provider: RunProvider, all: [String]) {
        var allowed = autoModels(for: provider)
        if allowed.isEmpty { allowed = all }
        allowed.removeAll(where: \.isEmpty)
        if let index = allowed.firstIndex(of: model) { allowed.remove(at: index) } else { allowed.append(model) }
        autoModels[provider.rawValue] = Set(allowed) == Set(all) ? nil : allowed.isEmpty ? AutoModel.none : allowed
    }

    func resetAutoModels(for provider: RunProvider) { autoModels[provider.rawValue] = nil }

    /// Whether "Auto" may use this agent's account: neither the agent nor the account is switched off.
    func autoAllows(_ provider: RunProvider, profileID: String) -> Bool {
        !autoAgentsOff.contains(provider.rawValue) && !autoAccountsOff.contains(profileID)
    }

    func setAutoAgent(_ provider: RunProvider, allowed: Bool) {
        autoAgentsOff.removeAll { $0 == provider.rawValue }
        if !allowed { autoAgentsOff.append(provider.rawValue) }
    }

    func setAutoAccount(_ profileID: String, allowed: Bool) {
        autoAccountsOff.removeAll { $0 == profileID }
        if !allowed { autoAccountsOff.append(profileID) }
    }

    func customModels(for provider: RunProvider) -> [String] { customModels[provider.rawValue] ?? [] }

    func rememberCustomModel(_ model: String, for provider: RunProvider) {
        customModels[provider.rawValue] = ModelPreferences.remembering(model, in: customModels(for: provider))
    }

    func profile(for provider: RunProvider) -> String? { defaultProfiles[provider.rawValue] }

    /// The effort last chosen for this agent, while the agent still offers it. An ACP agent's levels are the ones its
    /// session offered: the level stays, and a session that does not offer it skips it (see `AcpSessionSettings`).
    func effort(for provider: RunProvider) -> String? {
        defaultEfforts[provider.rawValue].flatMap { provider.usesACP || EffortLevels.isOffered($0, for: provider, model: nil) ? $0 : nil }
    }

    func setEffort(_ effort: String?, for provider: RunProvider) { defaultEfforts[provider.rawValue] = effort }

    func setProfile(_ profileID: String, for provider: RunProvider) { defaultProfiles[provider.rawValue] = profileID }

    /// A safe default that the agent actually supports.
    func permission(for provider: RunProvider) -> PermissionPolicy {
        provider.capabilities.policies.contains(defaultPermission) ? defaultPermission : .acceptEdits
    }

    // MARK: Per project

    /// The global defaults, as `ProjectSettings` reads them.
    var globalDefaults: SessionDefaults {
        SessionDefaults(provider: defaultProvider, models: defaultModels, permission: defaultPermission,
                        isolation: defaultIsolation, branchPrefix: WorktreeNaming.normalizedBranchPrefix(branchPrefix),
                        titleInstructions: titleInstructions, agentInstructions: agentInstructions,
                        browserSignIns: browserSignInPolicy, submodules: worktreeSubmodules, autoPull: autoPullDefaultBranch)
    }

    /// What a new session in this folder starts with: the folder's own overrides, the global values for the rest.
    func sessionDefaults(for folder: String?) -> SessionDefaults {
        ProjectSettings.resolve(global: globalDefaults, overrides: projectOverrides, folder: folder)
    }

    /// What a new session in this folder starts with in the composer, and in anything else that starts one for you.
    func composerDefaults(for folder: String?) -> ComposerDefaults {
        ProjectSettings.composerDefaults(global: globalDefaults, mode: defaultMode, profiles: defaultProfiles,
                                         efforts: defaultEfforts, overrides: projectOverrides,
                                         choices: folderChoices.choices(for: folder), folder: folder)
    }

    /// Keeps what the composer has chosen for its folder.
    func rememberFolderChoices(_ config: NewRunConfig) { folderChoices.remember(config) }

    /// Does this folder (or the project it belongs to) set the value itself?
    func isOverridden(_ key: ProjectSettingKey, for folder: String) -> Bool {
        guard let project = projectOverrides.project(containing: folder) else { return false }
        return projectOverrides.isOverridden(key, for: project)
    }

    func setOverride(_ key: ProjectSettingKey, _ value: String, for project: String) {
        projectOverrides.set(key, .string(value), for: project)
    }

    func resetOverride(_ key: ProjectSettingKey, for project: String) { projectOverrides.reset(key, for: project) }

    /// The agents switched off for the project this folder belongs to (raw values).
    func agentsOff(for folder: String?) -> Set<String> {
        ProjectSettings.agentsOff(overrides: projectOverrides, folder: folder)
    }

    /// Whether this agent may start sessions in the folder's project.
    func isAgentOn(_ provider: RunProvider, for folder: String?) -> Bool { !agentsOff(for: folder).contains(provider.rawValue) }

    func setAgent(_ provider: RunProvider, on: Bool, for project: String) {
        let off = ProjectSettings.agentsOff(projectOverrides.values(for: project))
        if let value = ProjectSettings.togglingAgent(provider.rawValue, on: on, in: off) {
            projectOverrides.set(.agentsOff, value, for: project)
        } else {
            projectOverrides.reset(.agentsOff, for: project)
        }
    }

    func isArchivedProject(_ path: String) -> Bool { ProjectSettings.isArchived(path, overrides: projectOverrides) }

    /// Archives a project out of the pickers, or brings it back. Its sessions, settings and files stay.
    func setArchived(_ archived: Bool, project path: String) {
        if archived { projectOverrides.set(.archived, .string("on"), for: path) } else { projectOverrides.reset(.archived, for: path) }
    }

    func projectIcon(_ path: String) -> ProjectIcon? { ProjectSettings.icon(path, overrides: projectOverrides) }

    func setProjectIcon(_ icon: ProjectIcon?, project path: String) {
        if let icon { projectOverrides.set(.icon, .string(icon.stored), for: path) } else { projectOverrides.reset(.icon, for: path) }
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
