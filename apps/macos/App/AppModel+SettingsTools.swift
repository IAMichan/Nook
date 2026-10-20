import Foundation

/// Nook's own settings from the chat: "zet het zoeken op het web uit", "praat Engels", "open de instellingen van mijn
/// koppelingen". The brain reads them with `get_settings` and proposes a change with `change_setting`; a change always
/// waits for the user's click (it is never one of the `safeTools`), is written to the audit log by the plan runner, and
/// can be undone. Which settings qualify is `SettingsCatalog`.
extension AppModel {
    // MARK: Tools

    func makeSettingsTools() -> [ToolSpec] {
        [
            ToolSpec(
                name: "get_settings",
                description: "Reads Nook's own settings (instellingen, Einstellungen, réglages, ajustes) with their current values and the options each one takes. Use it before change_setting when the current value matters, or when the user asks how Nook is set up.",
                schema: ["type": "object", "properties": [String: Any](), "required": [String]()],
                kind: .read,
                summarize: { _ in tr("settings.tool.readPlan") },
                tag: { _ in ("", .good) },
                run: { [weak self] _ in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    return self.settingsOverview()
                }
            ),
            ToolSpec(
                name: "change_setting",
                description: "Changes one of Nook's own settings for the user: switch web search, thinking along, reading the screens, reading answers aloud, the \"Hey Nook\" wake word, dictation, agent sounds, memory or lyrics on or off, or change the app language, the answer language, Nook's style (how it looks) or where Nook sits on screen. Only when the user asks for it; the user approves every change with a click. One call per setting.",
                schema: SettingsCatalog.changeSchema,
                kind: .action,
                summarize: { input in Self.settingPlanLine(input) },
                tag: { _ in (tr("settings.tool.tag"), .caution) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    return try self.applySetting(input)
                }
            ),
            ToolSpec(
                name: "open_settings",
                description: "Opens Nook's Settings window (instellingen) at a section, so the user can look or change something there themselves: brain, connections (koppelingen), agents, privacy, shortcuts, and more.",
                schema: [
                    "type": "object",
                    "properties": [
                        "section": ["type": "string", "enum": SettingsSection.allCases.map(\.rawValue), "description": "Which section to show."]
                    ],
                    "required": ["section"]
                ],
                kind: .action,
                summarize: { input in
                    let section = SettingsSection(rawValue: (input["section"] as? String) ?? "") ?? .start
                    return tr("settings.tool.openPlan", section.title)
                },
                tag: { _ in ("", .good) },
                run: { [weak self] input in
                    guard let self else { throw NookError(tr("app.unavailable")) }
                    let section = SettingsSection(rawValue: (input["section"] as? String) ?? "") ?? .start
                    self.openSettings(section: section)
                    return tr("settings.tool.opened", section.title)
                }
            )
        ]
    }

    // MARK: Plan line

    /// "Zoek op het web als dat nodig is → uit": what the plan card shows before the user approves.
    static func settingPlanLine(_ input: [String: Any]) -> String {
        let id = (input["setting"] as? String) ?? ""
        guard let entry = SettingsCatalog.entry(id) else { return tr("settings.tool.unknown") }
        let raw = (input["value"] as? String) ?? (input["value"] as? Bool).map { SettingsCatalog.value($0) } ?? ""
        let value = SettingsCatalog.value(raw, for: entry).map { settingValueLabel($0, for: entry) } ?? raw
        return tr("settings.tool.plan", tr("settings.tool.name.\(entry.id)"), value)
    }

    /// A value in words: "aan", "uit", "Nederlands", "Zwevend op het scherm".
    static func settingValueLabel(_ value: String, for entry: SettingsCatalog.Entry) -> String {
        switch value {
        case "on": return tr("settings.tool.on")
        case "off": return tr("settings.tool.off")
        case "auto": return tr("settings.tool.auto")
        case "notch": return tr("settings.notch.placementNotch")
        case "floating": return tr("settings.notch.placementFloating")
        case "minimal", "classic", "playful": return SettingsView.presetTitle(value)
        case "custom": return tr("settings.tool.custom")
        case "automatic", "saver", "full": return tr("settings.energy.mode.\(value)")
        default: return AppLanguage(rawValue: value)?.displayName ?? value
        }
    }

    // MARK: Reading and writing

    /// Every setting the chat may change, one per line: id, current value, options and what it does.
    func settingsOverview() -> String {
        SettingsCatalog.entries.map { entry in
            let options: String
            switch entry.kind {
            case .toggle: options = "on/off"
            case .choice(let values): options = values.joined(separator: "/")
            }
            let section = SettingsSection(rawValue: entry.section)?.title ?? entry.section
            return "\(entry.id) = \(currentSetting(entry.id)) [\(options)] — \(entry.about) (Settings › \(section))"
        }
        .joined(separator: "\n")
    }

    func applySetting(_ input: [String: Any]) throws -> String {
        guard let entry = SettingsCatalog.entry((input["setting"] as? String) ?? "") else {
            throw NookError(tr("settings.tool.unknown"))
        }
        let raw = (input["value"] as? String) ?? (input["value"] as? Bool).map { SettingsCatalog.value($0) } ?? ""
        guard let value = SettingsCatalog.value(raw, for: entry) else {
            throw NookError(tr("settings.tool.badValue", raw))
        }
        if entry.id == "wake_word", value == "on", !WakeWordService.supported {
            throw NookError(tr("settings.tool.noWakeWord"))
        }
        let old = currentSetting(entry.id)
        setSetting(entry.id, to: value)
        return SettingsCatalog.result(entry.id, value: value, old: old)
    }

    func currentSetting(_ id: String) -> String {
        switch id {
        case "app_language": return settings.appLanguage.rawValue
        case "answer_language": return settings.language
        case "notch_placement": return settings.placement
        case "nook_style": return NookLook.presets.first { $0.look == settings.nookLook }?.id ?? "custom"
        case "notch_on_all_screens": return SettingsCatalog.value(settings.notchOnAllScreens)
        case "hide_when_idle": return SettingsCatalog.value(settings.hideWhenIdle)
        case "open_on_hover": return SettingsCatalog.value(viewModel.openOnHover)
        case "energy_mode": return settings.energyMode.rawValue
        case "web_search": return SettingsCatalog.value(settings.webSearch)
        case "think_along": return SettingsCatalog.value(settings.autoWatch)
        case "track_screens": return SettingsCatalog.value(settings.liveScreen)
        case "screens_with_every_question": return SettingsCatalog.value(settings.screenWithEveryQuestion)
        case "speak_answers": return SettingsCatalog.value(settings.speakAnswers)
        case "wake_word": return SettingsCatalog.value(settings.wakeWord)
        case "dictation": return SettingsCatalog.value(FlowStore.shared.enabled)
        case "agent_sounds": return SettingsCatalog.value(settings.sounds)
        case "agent_notice": return settings.agentNotice.rawValue
        case "use_memory": return SettingsCatalog.value(settings.useMemory)
        case "learn_from_chats": return SettingsCatalog.value(settings.learnFromChats)
        case "online_lyrics": return SettingsCatalog.value(settings.onlineLyrics)
        default: return ""
        }
    }

    func setSetting(_ id: String, to value: String) {
        let on = value == "on"
        switch id {
        case "app_language": if let language = AppLanguage(rawValue: value) { settings.appLanguage = language }
        case "answer_language": settings.language = value
        case "notch_placement": settings.placement = value
        case "nook_style": if let preset = NookLook.presets.first(where: { $0.id == value }) { settings.nookLook = preset.look }
        case "notch_on_all_screens": settings.notchOnAllScreens = on
        case "hide_when_idle": settings.hideWhenIdle = on
        case "open_on_hover": viewModel.openOnHover = on
        case "energy_mode": if let mode = EnergyMode(rawValue: value) { settings.energyMode = mode }
        case "web_search": settings.webSearch = on
        case "think_along": settings.autoWatch = on
        case "track_screens": settings.liveScreen = on
        case "screens_with_every_question": settings.screenWithEveryQuestion = on
        case "speak_answers": settings.speakAnswers = on
        case "wake_word": settings.wakeWord = on
        case "dictation":
            FlowStore.shared.enabled = on
            FlowDictation.shared.refresh()
        case "agent_sounds": settings.sounds = on
        case "agent_notice": if let style = AgentNoticeStyle(rawValue: value) { settings.agentNotice = style }
        case "use_memory": settings.useMemory = on
        case "learn_from_chats": settings.learnFromChats = on
        case "online_lyrics": settings.onlineLyrics = on
        default: break
        }
    }
}
