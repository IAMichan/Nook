import Foundation

/// One setting the sidebar search finds: its own name (a text key that Settings already shows) and where it lives.
struct SettingsSearchHit: Identifiable {
    let key: String
    let section: SettingsSection
    /// The part of the Typing page the setting lives on (0 completing, 1 dictating), when the section has parts.
    var typingPart: Int? = nil

    var id: String { key }
    var title: String { tr(key) }
}

/// The sidebar search of Settings: every setting by the name it has on screen, plus the section names, in the current
/// language. Typing "sleutel", "iPhone" or "taal" goes straight to the right page.
enum SettingsSearch {
    /// A setting's text key, the section that shows it and, on the Typing page, the part it is in.
    struct Entry {
        let key: String
        let section: SettingsSection
        let typingPart: Int?

        init(_ key: String, _ section: SettingsSection, typingPart: Int? = nil) {
            self.key = key
            self.section = section
            self.typingPart = typingPart
        }
    }

    /// Text key of a setting → the section that shows it.
    static let index: [Entry] = [
        .init("settings.start.glance", .start),
        .init("settings.overview.appLanguage", .general),
        .init("settings.brain.answerLanguage", .general),
        .init("flow.settings.translate", .autocomplete, typingPart: 1),
        .init("settings.display.accent", .appearance),
        .init("settings.display.look", .appearance),
        .init("settings.display.eyes", .appearance),
        .init("settings.display.mouth", .appearance),
        .init("settings.display.glow", .appearance),
        .init("settings.buddy.title", .assistant),
        .init("settings.buddy.birthday", .assistant),
        .init("settings.notch.placement", .general),
        .init("settings.notch.allScreens", .general),
        .init("settings.notch.hideWhenIdle", .general),
        .init("settings.notch.openOnHover", .general),
        .init("settings.window.openAtLaunch", .general),
        .init("settings.notch.demoData", .general),
        .init("settings.energy.title", .general),
        .init("settings.energy.mode", .general),
        .init("settings.overview.talkNook", .shortcuts),
        .init("settings.overview.askTyping", .shortcuts),
        .init("settings.overview.lookScreen", .shortcuts),
        .init("flow.settings.key", .shortcuts),
        .init("autocomplete.section.keys", .shortcuts),
        .init("keys.title", .shortcuts),
        .init("keys.file.title", .shortcuts),
        .init("notices.settings.how", .notifications),
        .init("notices.settings.agents", .notifications),
        .init("notices.settings.chats", .notifications),
        .init("notices.settings.suggestions", .notifications),
        .init("agentNotice.watching", .notifications),
        .init("settings.voice.agentSound", .notifications),
        .init("settings.voice.customSounds", .notifications),
        .init("quiet.title", .notifications),
        .init("quiet.sharing", .notifications),
        .init("quiet.meeting", .notifications),
        .init("quiet.hideFromCaptures", .notifications),
        .init("quiet.showInScreenshots", .notifications),
        .init("companion.push.enable", .notifications),
        .init("companion.push.quiet", .notifications),
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
        .init("memory.settings.use", .assistant),
        .init("memory.settings.learn", .assistant),
        .init("memory.settings.clear", .assistant),
        .init("autocomplete.enable", .autocomplete, typingPart: 0),
        .init("autocomplete.section.model", .autocomplete, typingPart: 0),
        .init("autocomplete.section.battery", .autocomplete, typingPart: 0),
        .init("autocomplete.section.apps", .autocomplete, typingPart: 0),
        .init("autocomplete.section.personal", .autocomplete, typingPart: 0),
        .init("autocomplete.emoji", .autocomplete, typingPart: 0),
        .init("flow.settings.enable", .autocomplete, typingPart: 1),
        .init("flow.settings.dictionary", .autocomplete, typingPart: 1),
        .init("parakeet.title", .autocomplete, typingPart: 1),
        .init("settings.voice.speakAnswers", .autocomplete, typingPart: 1),
        .init("settings.voice.wakeWord", .autocomplete, typingPart: 1),
        .init("hub.add", .connections),
        .init("hub.chats", .connections),
        .init("hub.services", .connections),
        .init("hub.own", .connections),
        .init("settings.connections.onYourMac", .connections),
        .init("whatsapp.settings.title", .connections),
        .init("chats.settings.collect", .connections),
        .init("chats.settings.readOnOpen", .connections),
        .init("chats.settings.sources", .connections),
        .init("chats.giphy.title", .connections),
        .init("gitlab.title", .connections),
        .init("mcp.add", .connections),
        .init("settings.agents.linkAgents", .agents),
        .init("settings.agents.accounts", .agents),
        .init("acp.title", .agents),
        .init("settings.agents.usage", .agents),
        .init("settings.agents.subscriptions", .agents),
        .init("ws.usage.byModel", .agents),
        .init("settings.agents.weekRecap", .agents),
        .init("settings.ws.provider", .workspace),
        .init("settings.ws.worktreeRoot", .workspace),
        .init("settings.ws.editor", .workspace),
        .init("settings.ws.terminal", .workspace),
        .init("sched.title", .workspace),
        .init("settings.bridge.title", .workspace),
        .init("settings.devices.iphone", .connections),
        .init("companion.enable", .connections),
        .init("remote.title", .workspace),
        .init("settings.privacy.levelTitle", .privacy),
        .init("settings.privacy.permissions", .privacy),
        .init("settings.privacy.neverRead.title", .privacy),
        .init("settings.private.title", .privacy),
        .init("settings.privacy.whatLeavesMac", .privacy),
        .init("settings.privacy.forgetScreenText", .privacy),
        .init("settings.pulls.title", .connections),
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
            .map { SettingsSearchHit(key: $0.key, section: $0.section, typingPart: $0.typingPart) }
        return sections + settings
    }
}
