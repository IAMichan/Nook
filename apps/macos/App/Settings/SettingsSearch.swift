import Foundation

/// One setting the sidebar search finds: its own name (a text key that Settings already shows) and where it lives.
struct SettingsSearchHit: Identifiable {
    let key: String
    let section: SettingsSection

    var id: String { key }
    var title: String { tr(key) }
}

/// The sidebar search of Settings: every setting by the name it has on screen, plus the section names, in the current
/// language. Typing "sleutel", "iPhone" or "taal" goes straight to the right page.
enum SettingsSearch {
    /// Text key of a setting → the section that shows it.
    static let index: [(key: String, section: SettingsSection)] = [
        ("settings.start.glance", .start),
        ("settings.overview.appLanguage", .general),
        ("settings.brain.answerLanguage", .general),
        ("flow.settings.translate", .autocomplete),
        ("settings.display.accent", .appearance),
        ("settings.display.look", .appearance),
        ("settings.display.eyes", .appearance),
        ("settings.display.mouth", .appearance),
        ("settings.display.glow", .appearance),
        ("wardrobe.title", .appearance),
        ("settings.buddy.title", .assistant),
        ("settings.buddy.birthday", .assistant),
        ("settings.notch.placement", .general),
        ("settings.notch.allScreens", .general),
        ("settings.notch.hideWhenIdle", .general),
        ("settings.notch.openOnHover", .general),
        ("settings.notch.demoData", .general),
        ("settings.energy.title", .general),
        ("settings.energy.mode", .general),
        ("settings.overview.talkNook", .shortcuts),
        ("settings.overview.askTyping", .shortcuts),
        ("settings.overview.lookScreen", .shortcuts),
        ("flow.settings.key", .shortcuts),
        ("autocomplete.section.keys", .shortcuts),
        ("keys.title", .shortcuts),
        ("keys.file.title", .shortcuts),
        ("notices.settings.how", .notifications),
        ("notices.source.agents", .notifications),
        ("notices.source.chats", .notifications),
        ("notices.source.nook", .notifications),
        ("notices.source.suggestions", .notifications),
        ("notices.settings.apps", .notifications),
        ("agentNotice.watching", .notifications),
        ("settings.voice.agentSound", .notifications),
        ("settings.voice.customSounds", .notifications),
        ("quiet.title", .notifications),
        ("quiet.sharing", .notifications),
        ("quiet.meeting", .notifications),
        ("quiet.hideFromCaptures", .notifications),
        ("quiet.showInScreenshots", .notifications),
        ("companion.push.enable", .notifications),
        ("companion.push.quiet", .notifications),
        ("settings.brain.apiKey", .brain),
        ("settings.brain.claudeCodeSub", .brain),
        ("settings.brain.model", .brain),
        ("settings.brain.provider", .brain),
        ("settings.brain.localModelTitle", .brain),
        ("settings.quality.title", .brain),
        ("settings.assistant.trackAllScreens", .assistant),
        ("settings.assistant.useScreensEveryQuestion", .assistant),
        ("settings.assistant.webSearch", .assistant),
        ("settings.assistant.thinkAlongToggle", .assistant),
        ("nookAccess.title", .assistant),
        ("memory.settings.use", .assistant),
        ("memory.settings.learn", .assistant),
        ("memory.settings.clear", .assistant),
        ("autocomplete.enable", .autocomplete),
        ("autocomplete.section.model", .autocomplete),
        ("autocomplete.section.battery", .autocomplete),
        ("autocomplete.section.apps", .autocomplete),
        ("autocomplete.section.personal", .autocomplete),
        ("autocomplete.emoji", .autocomplete),
        ("flow.settings.enable", .autocomplete),
        ("flow.settings.dictionary", .autocomplete),
        ("parakeet.title", .autocomplete),
        ("settings.voice.speakAnswers", .autocomplete),
        ("settings.voice.wakeWord", .autocomplete),
        ("hub.add", .connections),
        ("hub.chats", .connections),
        ("hub.services", .connections),
        ("hub.own", .connections),
        ("settings.connections.onYourMac", .connections),
        ("whatsapp.settings.title", .connections),
        ("chats.settings.collect", .connections),
        ("chats.settings.readOnOpen", .connections),
        ("chats.settings.sources", .connections),
        ("chats.giphy.title", .connections),
        ("gitlab.title", .connections),
        ("mcp.add", .connections),
        ("settings.connections.crypto", .connections),
        ("settings.agents.linkAgents", .agents),
        ("settings.agents.accounts", .agents),
        ("acp.title", .agents),
        ("settings.agents.usage", .agents),
        ("settings.agents.subscriptions", .agents),
        ("ws.usage.byModel", .agents),
        ("settings.agents.weekRecap", .agents),
        ("settings.ws.provider", .workspace),
        ("settings.ws.worktreeRoot", .workspace),
        ("settings.ws.editor", .workspace),
        ("settings.ws.terminal", .workspace),
        ("sched.title", .workspace),
        ("settings.bridge.title", .workspace),
        ("settings.devices.iphone", .connections),
        ("companion.enable", .connections),
        ("remote.title", .workspace),
        ("settings.privacy.levelTitle", .privacy),
        ("settings.privacy.permissions", .privacy),
        ("settings.privacy.neverRead.title", .privacy),
        ("settings.private.title", .privacy),
        ("settings.privacy.whatLeavesMac", .privacy),
        ("settings.privacy.forgetScreenText", .privacy),
        ("settings.pulls.title", .connections),
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
            .map { SettingsSearchHit(key: $0.key, section: $0.section) }
        return sections + settings
    }
}
