import Foundation

/// One setting the sidebar search finds: its own name (a text key that Settings already shows) and where it lives.
struct SettingsSearchHit: Identifiable {
    let key: String
    let section: SettingsSection
    /// The tab of `section` it is on, for a page with tabs.
    var tab: Int? = nil

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
        /// The tab of `section` it is on, for a page with tabs (`SettingsSection.tabs`).
        let tab: Int?

        init(_ key: String, _ section: SettingsSection, tab: Int? = nil) {
            self.key = key
            self.section = section
            self.tab = tab
        }
    }

    /// Text key of a setting → the section that shows it.
    static let index: [Entry] = [
        .init("settings.start.glance", .start),
        .init("settings.overview.appLanguage", .general),
        .init("settings.brain.answerLanguage", .general),
        .init("flow.settings.translate", .dictation),
        .init("settings.display.accent", .appearance),
        .init("settings.display.look", .appearance),
        .init("settings.display.eyes", .appearance),
        .init("settings.display.mouth", .appearance),
        .init("settings.display.glow", .appearance),
        .init("settings.buddy.title", .appearance),
        .init("settings.buddy.birthday", .appearance),
        .init("settings.notch.placement", .notch),
        .init("settings.notch.allScreens", .notch),
        .init("settings.notch.hideWhenIdle", .notch),
        .init("settings.notch.openOnHover", .notch),
        .init("settings.window.openAtLaunch", .notch),
        .init("update.settings.title", .general),
        .init("settings.notch.demoData", .general),
        .init("settings.energy.title", .general),
        .init("settings.energy.mode", .general),
        .init("settings.overview.talkNook", .shortcuts),
        .init("settings.overview.askTyping", .shortcuts),
        .init("settings.overview.lookScreen", .shortcuts),
        .init("flow.settings.key", .dictation),
        .init("autocomplete.section.keys", .autocomplete),
        .init("keys.title", .shortcuts),
        .init("keys.file.title", .shortcuts),
        .init("notices.settings.how", .notifications, tab: 0),
        .init("notices.settings.agents", .notifications, tab: 1),
        .init("notices.settings.chats", .notifications, tab: 1),
        .init("notices.settings.suggestions", .notifications, tab: 1),
        .init("agentNotice.watching", .notifications, tab: 0),
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
        .init("memory.settings.use", .memory),
        .init("memory.settings.learn", .memory),
        .init("memory.settings.clear", .memory),
        .init("autocomplete.enable", .autocomplete),
        .init("autocomplete.section.model", .autocomplete),
        .init("autocomplete.section.battery", .autocomplete),
        .init("autocomplete.section.apps", .autocomplete),
        .init("autocomplete.section.personal", .autocomplete),
        .init("autocomplete.emoji", .autocomplete),
        .init("flow.settings.enable", .dictation),
        .init("flow.settings.dictionary", .dictation),
        .init("parakeet.title", .sound),
        .init("settings.voice.speakAnswers", .sound),
        .init("settings.voice.wakeWord", .sound),
        .init("hub.add", .connections),
        .init("hub.chats", .chats),
        .init("hub.services", .connections),
        .init("hub.own", .connections),
        .init("settings.connections.onYourMac", .connections),
        .init("whatsapp.settings.title", .chats),
        .init("chats.settings.collect", .chats),
        .init("chats.settings.readOnOpen", .chats),
        .init("chats.settings.sources", .chats),
        .init("chats.giphy.title", .chats),
        .init("gitlab.title", .connections),
        .init("mcp.add", .connections),
        .init("settings.agents.linkAgents", .agents),
        .init("settings.agents.accounts", .agents),
        .init("acp.title", .agents),
        .init("settings.agents.usage", .usage),
        .init("settings.agents.subscriptions", .usage),
        .init("ws.usage.byModel", .usage),
        .init("settings.agents.weekRecap", .usage),
        .init("settings.ws.provider", .sessions, tab: 0),
        .init("settings.ws.worktreeRoot", .sessions, tab: 0),
        .init("settings.ws.editor", .sessions, tab: 1),
        .init("settings.ws.terminal", .sessions, tab: 1),
        .init("sched.title", .automation),
        .init("settings.bridge.title", .automation),
        .init("settings.devices.iphone", .iphone),
        .init("companion.enable", .iphone),
        .init("remote.title", .machines),
        .init("settings.privacy.levelTitle", .privacy, tab: 0),
        .init("settings.privacy.permissions", .privacy, tab: 1),
        .init("settings.privacy.neverRead.title", .privacy, tab: 1),
        .init("settings.private.title", .privacy, tab: 2),
        .init("settings.privacy.whatLeavesMac", .privacy, tab: 0),
        .init("settings.privacy.forgetScreenText", .privacy, tab: 0),
        .init("settings.pulls.title", .pullRequests),
        .init("settings.ws.commitStyle", .sessions, tab: 1),
        .init("settings.ws.autoTitles", .sessions, tab: 2),
        .init("ws.section.restart", .sessions, tab: 2),
        .init("ws.section.tidy", .sessions, tab: 3),
        .init("settings.ws.showCost", .usage),
        .init("settings.ws.codexAppServer", .agents),
        .init("settings.ws.trafficLog", .automation),
        .init("settings.privacy.onlineLyrics", .connections),
    ]

    /// Matches on a setting's name, its section and the section's subtitle; sections themselves come first.
    static func results(_ query: String) -> [SettingsSearchHit] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        func matches(_ value: String) -> Bool { value.localizedCaseInsensitiveContains(text) }
        let sections = SettingsSection.allCases
            .filter { matches($0.title) || matches($0.subtitle) }
            .map { SettingsSearchHit(key: "settings.section.\($0.rawValue)", section: $0) }
        let settings = index
            .filter { matches(tr($0.key)) }
            .map { SettingsSearchHit(key: $0.key, section: $0.section, tab: $0.tab) }
        return sections + settings
    }
}
