import SwiftUI

/// Settings › Notifications, in two tabs: how (one choice per source for how its notices show: a card, one line, a
/// macOS notification, or only in the list under the bell), and from whom (one switch per app for whether it may notify
/// at all, every list searchable at once). Every notice Nook gives follows these (`AppModel.deliverNotice`), so what is
/// set here is what happens everywhere.
struct NoticeRulesSettings: View {
    enum Part { case how, apps }

    @ObservedObject var settings: AppSettings
    @ObservedObject var thinkAlong: ThinkAlong
    var part: Part = .how
    @ObservedObject private var notifier = SystemNotifier.shared
    @ObservedObject private var capture = ChatCaptureService.shared
    /// Narrows every app list at once.
    @State private var query = ""

    var body: some View {
        switch part {
        case .how: how
        case .apps: apps
        }
    }

    private var how: some View {
        Group {
            Section {
                ForEach(NoticeSource.allCases) { source in
                    Picker(selection: style(source)) {
                        ForEach(NoticeStyle.allCases) { Text(tr($0.titleKey)).tag($0) }
                    } label: {
                        SettingLabel(tr(source.titleKey), hint: tr(source.detailKey))
                    }
                }
                if notifier.blocked, settings.noticeRules.usesSystem {
                    LabeledContent(tr("noticeDelivery.blocked")) {
                        Button(tr("noticeDelivery.openSettings")) { SystemNotifier.openSystemSettings() }
                    }
                }
                SettingToggle(tr("agentNotice.watching"), detail: tr("agentNotice.watchingDetail"),
                              isOn: $settings.quietWhileWatching)
                quietHours
            } header: {
                SettingsSectionTitle(tr("notices.settings.how"), info: tr("notices.settings.howFooter"))
            }
            .onAppear { if settings.noticeRules.usesSystem { notifier.requestAccess() } }
        }
    }

    /// Quiet hours for every notice, on the Mac and on the phone (`NoticeRules.quietHours`).
    @ViewBuilder
    private var quietHours: some View {
        SettingToggle(tr("notices.quietHours.title"), detail: tr("notices.quietHours.detail"), isOn: Binding(
            get: { settings.noticeRules.quietHours != nil },
            set: { on in settings.noticeRules.quietHours = on ? (settings.noticeRules.quietHours ?? .evening) : nil }))
        if let hours = settings.noticeRules.quietHours {
            HStack {
                Stepper(tr("companion.push.from", hours.from), value: quietHour(\.from), in: 0...23)
                Stepper(tr("companion.push.to", hours.to), value: quietHour(\.to), in: 0...23)
            }
            Toggle(tr("companion.push.urgent"), isOn: Binding(
                get: { settings.noticeRules.quietHours?.allowsUrgent ?? true },
                set: { settings.noticeRules.quietHours?.allowsUrgent = $0 }))
        }
    }

    private func quietHour(_ keyPath: WritableKeyPath<QuietHours, Int>) -> Binding<Int> {
        Binding(get: { settings.noticeRules.quietHours?[keyPath: keyPath] ?? 0 },
                set: { settings.noticeRules.quietHours?[keyPath: keyPath] = $0 })
    }

    /// Which apps may notify, per source; one search over all of them, as the chat apps alone can be a long list.
    private var apps: some View {
        Group {
            Section {
                NookSearchField(prompt: tr("notices.settings.searchApps"), text: $query, style: .inline)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty, !anyMatch {
                    SettingNote(tr("settings.search.none"))
                }
            }
            appSection(.agents, header: tr("notices.settings.agents"), info: tr("notices.settings.agentsFooter"),
                       apps: AgentKind.allCases.map { AppRow(id: $0.rawValue, name: $0.name, icon: $0.rawValue, symbol: "terminal") })
            appSection(.chats, header: tr("notices.settings.chats"), info: tr("notices.settings.chatsFooter"),
                       apps: capture.sources.apps.map {
                           AppRow(id: $0.id, name: $0.name, icon: $0.id, domain: $0.site, symbol: "bubble.left.fill")
                       })
            if !thinkAlong.mutedApps.isEmpty {
                appSection(.suggestions, header: tr("notices.settings.suggestions"), info: tr("notices.settings.suggestionsFooter"),
                           apps: thinkAlong.mutedApps.sorted { $0.value < $1.value }.map {
                               AppRow(id: $0.key, name: $0.value, icon: nil, symbol: "app.dashed")
                           })
            }
        }
    }

    /// Whether any list has an app for the search.
    private var anyMatch: Bool {
        let text = query.trimmingCharacters(in: .whitespaces)
        let names = AgentKind.allCases.map(\.name) + capture.sources.apps.map(\.name) + Array(thinkAlong.mutedApps.values)
        return names.contains { $0.localizedCaseInsensitiveContains(text) }
    }

    /// One app in a source's list.
    private struct AppRow: Identifiable {
        var id: String
        var name: String
        /// The source id whose icon stands for it (`SourceBrand`), when there is one.
        var icon: String?
        var domain: String? = nil
        var symbol: String
    }

    /// A source's apps, each with its own switch. Greyed out while the source shows nothing at all.
    private func appSection(_ source: NoticeSource, header: String, info: String, apps: [AppRow]) -> some View {
        // A tab of its own, so the lists are open; how many may notify stands beside each list's name.
        let on = apps.count(where: { settings.noticeRules.isOn(source, app: $0.id) })
        let text = query.trimmingCharacters(in: .whitespaces)
        let shown = text.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(text) }
        return Group {
            if !shown.isEmpty {
                Section {
                    ForEach(shown) { row in
                        Toggle(isOn: isOn(source, app: row.id)) {
                            HStack(spacing: NookTheme.Spacing.md) {
                                SiteIcon(domain: row.domain, fallback: row.symbol, tint: NookTheme.textSecondary, size: 20, source: row.icon)
                                    .frame(width: 22)
                                Text(row.name)
                            }
                        }
                    }
                } header: {
                    SettingsSectionTitle(header + " · " + tr("notices.settings.onCount", on, apps.count), info: info)
                }
                .disabled(settings.noticeRules.style(for: source) == .off)
            }
        }
    }

    private func style(_ source: NoticeSource) -> Binding<NoticeStyle> {
        Binding(get: { settings.noticeRules.style(for: source) },
                set: { style in
                    settings.noticeRules.setStyle(style, for: source)
                    if style == .system { notifier.requestAccess() }
                })
    }

    private func isOn(_ source: NoticeSource, app: String) -> Binding<Bool> {
        Binding(get: { settings.noticeRules.isOn(source, app: app) },
                set: { settings.noticeRules.set(source, app: app, on: $0) })
    }
}
