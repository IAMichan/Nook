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
        ("settings.overview.readyToUse", .start),
        ("settings.overview.appLanguage", .general),
        ("settings.brain.answerLanguage", .general),
        ("flow.settings.translate", .general),
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
        ("settings.voice.agentSound", .notifications),
        ("settings.voice.customSounds", .notifications),
        ("quiet.title", .notifications),
        ("quiet.sharing", .notifications),
        ("quiet.meeting", .notifications),
        ("quiet.hideFromCaptures", .notifications),
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
        ("settings.assistant.autoRunSafe", .assistant),
        ("memory.settings.use", .memory),
        ("memory.settings.learn", .memory),
        ("memory.settings.clear", .memory),
        ("autocomplete.enable", .autocomplete),
        ("autocomplete.section.model", .autocomplete),
        ("autocomplete.section.apps", .autocomplete),
        ("autocomplete.section.personal", .autocomplete),
        ("autocomplete.emoji", .autocomplete),
        ("flow.settings.enable", .dictation),
        ("flow.settings.dictionary", .dictation),
        ("parakeet.title", .dictation),
        ("settings.voice.speakAnswers", .dictation),
        ("settings.voice.wakeWord", .dictation),
        ("settings.connections.onYourMac", .connections),
        ("settings.connections.oneClick", .connections),
        ("whatsapp.settings.title", .connections),
        ("gitlab.title", .connections),
        ("mcp.add", .connections),
        ("settings.connections.crypto", .connections),
        ("settings.agents.linkAgents", .agents),
        ("settings.agents.accounts", .agents),
        ("acp.title", .agents),
        ("settings.agents.usage", .usage),
        ("settings.agents.subscriptions", .usage),
        ("ws.usage.byModel", .usage),
        ("settings.agents.weekRecap", .agents),
        ("settings.ws.provider", .workspace),
        ("settings.ws.worktreeRoot", .workspace),
        ("settings.ws.editor", .workspace),
        ("settings.ws.terminal", .workspace),
        ("sched.title", .workspace),
        ("settings.bridge.title", .workspace),
        ("companion.enable", .devices),
        ("remote.title", .devices),
        ("settings.privacy.permissions", .privacy),
        ("settings.private.title", .privacy),
        ("settings.privacy.whatLeavesMac", .privacy),
        ("settings.privacy.forgetScreenText", .privacy)
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
