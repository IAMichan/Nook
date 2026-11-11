import Foundation

/// One setting the sidebar search finds: its own name (a text key that Settings already shows) and where it lives.
struct SettingsSearchHit: Identifiable {
    let key: String
    let section: SettingsSection
    /// A page itself, not a setting on it: opening it lights nothing.
    var isSection = false

    var id: String { key }
    var title: String { tr(key) }
}

/// The sidebar search of Settings: every setting by the name it has on screen, plus the section names, in the current
/// language. Typing "sleutel", "iPhone" or "taal" goes straight to the right page.
enum SettingsSearch {
    /// A setting's text key and the section that shows it.
    struct Entry {
        let key: String
        let section: SettingsSection
        init(_ key: String, _ section: SettingsSection) {
            self.key = key
            self.section = section
        }
    }

    /// Text key of a setting → the section that shows it.
    static let index: [Entry] = [
        .init("settings.start.glance", .start),
        .init("settings.overview.appLanguage", .general),
        .init("settings.brain.answerLanguage", .general),
        .init("flow.settings.translate", .dictation),
        .init("settings.display.accent", .appearance),
        .init("settings.appearance.style", .appearance),
        .init("settings.display.eyes", .appearance),
        .init("settings.display.mouth", .appearance),
        .init("settings.display.glow", .appearance),
        .init("settings.buddy.title", .appearance),
        .init("settings.buddy.birthday", .appearance),
        .init("settings.notch.show", .notch),
        .init("settings.notch.placement", .notch),
        .init("settings.notch.allScreens", .notch),
        .init("settings.notch.hideWhenIdle", .notch),
        .init("settings.notch.openOnHover", .notch),
        .init("settings.window.openAtLaunch", .notch),
        .init("update.settings.title", .maintenance),
        .init("settings.notch.demoData", .maintenance),
        .init("settings.energy.title", .maintenance),
        .init("settings.energy.mode", .maintenance),
        .init("settings.overview.talkNook", .shortcuts),
        .init("settings.overview.askTyping", .shortcuts),
        .init("settings.overview.lookScreen", .shortcuts),
        .init("flow.settings.key", .dictation),
        .init("autocomplete.section.keys", .autocomplete),
        .init("keys.title", .shortcuts),
        .init("keys.file.title", .shortcuts),
        .init("notices.settings.how", .notifications),
        .init("notices.settings.agents", .notificationApps),
        .init("notices.settings.chats", .notificationApps),
        .init("notices.settings.suggestions", .notificationApps),
        .init("agentNotice.watching", .notifications),
        .init("settings.voice.agentSound", .sound),
        .init("settings.voice.customSounds", .sound),
        .init("quiet.title", .notch),
        .init("quiet.sharing", .notch),
        .init("quiet.meeting", .notch),
        .init("quiet.hideFromCaptures", .notch),
        .init("quiet.showInScreenshots", .notch),
        .init("companion.push.enable", .iphone),
        .init("companion.push.quiet", .iphone),
        .init("settings.brain.apiKey", .brain),
        .init("settings.brain.claudeCodeSub", .brain),
        .init("settings.brain.model", .brain),
        .init("settings.brain.provider", .brain),
        .init("settings.brain.localModelTitle", .brain),
        .init("settings.quality.title", .brain),
        .init("settings.assistant.trackAllScreens", .assistant),
        .init("settings.assistant.useScreensEveryQuestion", .assistant),
        .init("settings.assistant.selectionAsk", .assistant),
        .init("settings.assistant.webSearch", .assistant),
        .init("settings.assistant.thinkAlongToggle", .assistant),
        .init("nookAccess.title", .assistant),
        .init("doubletap.settings.title", .assistant),
        .init("doubletap.settings.enable", .assistant),
        .init("doubletap.settings.suggest", .assistant),
        .init("memory.settings.use", .memory),
        .init("memory.settings.learn", .memory),
        .init("memory.settings.clear", .memory),
        .init("instructions.style.title", .instructions),
        .init("instructions.prompts.title", .instructions),
        .init("instructions.spaces.title", .instructions),
        .init("instructions.context.title", .instructions),
        .init("autocomplete.enable", .autocomplete),
        .init("autocomplete.section.model", .autocomplete),
        .init("autocomplete.section.battery", .autocomplete),
        .init("autocomplete.section.apps", .autocompleteApps),
        .init("autocomplete.section.personal", .autocompleteStyle),
        .init("autocomplete.emoji", .autocompleteStyle),
        .init("autocomplete.section.extras", .autocompleteStyle),
        .init("privacy.log.search", .activityLog),
        .init("settings.ws.browserSearch", .openIn),
        .init("settings.ws.linkTarget", .openIn),
        .init("settings.ws.inboxProjects", .general),
        .init("settings.ws.confirmQuit", .general),
        .init("settings.general.sessionList", .general),
        .init("settings.general.confirmations", .general),
        .init("settings.archive.sessions", .archive),
        .init("settings.archive.conversations", .archive),
        .init("settings.projects.project", .projects),
        .init("flow.settings.enable", .dictation),
        .init("flow.settings.dictionary", .dictation),
        .init("parakeet.title", .sound),
        .init("settings.voice.speakAnswers", .sound),
        .init("settings.voice.wakeWord", .sound),
        .init("hub.add", .connections),
        .init("hub.chats", .chats),
        .init("hub.chats.add", .chats),
        .init("hub.services", .connections),
        .init("hub.own", .connections),
        .init("settings.connections.onYourMac", .connections),
        .init("chats.settings.collect", .chats),
        .init("chats.settings.readOnOpen", .chats),
        .init("chats.settings.otherApps", .chats),
        .init("chats.settings.addField", .chats),
        .init("chats.giphy.title", .chats),
        .init("mcp.add", .connections),
        .init("settings.agents.linkAgents", .agents),
        .init("settings.agents.accounts", .agents),
        .init("acp.title", .agents),
        .init("settings.agents.subscriptions", .usage),
        .init("ws.usage.byModel", .usage),
        .init("settings.agents.weekRecap", .usage),
        .init("settings.ws.provider", .sessions),
        .init("settings.ws.worktreeRoot", .worktrees),
        .init("settings.ws.branchPrefix", .worktrees),
        .init("ws.worktrees.title", .worktrees),
        .init("settings.ws.editor", .openIn),
        .init("settings.ws.terminal", .openIn),
        .init("sched.title", .automation),
        .init("settings.bridge.title", .automation),
        .init("secrets.providers.title", .automation),
        .init("settings.devices.iphone", .iphone),
        .init("companion.enable", .iphone),
        .init("remote.title", .machines),
        .init("settings.privacy.levelTitle", .privacy),
        .init("settings.privacy.permissions", .permissions),
        .init("settings.privacy.neverRead.title", .permissions),
        .init("settings.private.title", .onDevice),
        .init("settings.privacy.whatLeavesMac", .privacy),
        .init("settings.privacy.forgetScreenText", .privacy),
        .init("settings.pulls.title", .pullRequests),
        .init("settings.ws.commitStyle", .pullRequests),
        .init("settings.ws.watchNewPullRequests", .pullRequests),
        .init("codeHost.title", .pullRequests),
        .init("gitlab.title", .pullRequests),
        .init("settings.ws.autoTitles", .sessions),
        .init("textgen.section", .sessions),
        .init("textgen.next.setting", .sessions),
        .init("textgen.task.gitText", .sessions),
        .init("settings.ws.timelineDetail", .sessions),
        .init("settings.ws.screenReader", .sessions),
        .init("ws.section.restart", .sessions),
        .init("ws.section.tidy", .sessions),
        .init("settings.ws.showCost", .usage),
        .init("settings.ws.codexAppServer", .agents),
        .init("settings.ws.trafficLog", .maintenance),
        .init("settings.maintenance.diagnostics", .maintenance),
        .init("diagnostics.export", .maintenance),
        .init("settings.about.version", .about),
        .init("settings.about.license", .about),
        .init("settings.about.report", .about),
        .init("settings.privacy.onlineLyrics", .connections),
    ]

    /// Matches on a setting's name, its section and the section's subtitle; sections themselves come first.
    static func results(_ query: String) -> [SettingsSearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(text) }
        let sections = SettingsSection.allCases
            .filter { matches($0.title) || matches($0.subtitle) }
            .map { SettingsSearchHit(key: "settings.section.\($0.rawValue)", section: $0, isSection: true) }
        let settings = index
            .filter { matches(tr($0.key)) }
            .map { SettingsSearchHit(key: $0.key, section: $0.section) }
        return sections + settings
    }
}
