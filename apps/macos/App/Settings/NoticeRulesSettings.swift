import SwiftUI

/// Settings › Notifications: one choice per source for how its notices show (a card, one line, a macOS notification,
/// or only in the list under the bell), and one switch per app for whether it may notify at all. Every notice Nook gives
/// follows these (`AppModel.deliverNotice`), so what is set here is what happens everywhere.
struct NoticeRulesSettings: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var thinkAlong: ThinkAlong
    @ObservedObject private var notifier = SystemNotifier.shared
    @ObservedObject private var capture = ChatCaptureService.shared

    var body: some View {
        Group {
            Section {
                ForEach(NoticeSource.allCases) { source in
                    Picker(selection: style(source)) {
                        ForEach(NoticeStyle.allCases) { Text(tr($0.titleKey)).tag($0) }
                    } label: {
                        SettingLabel(tr(source.titleKey), detail: tr(source.detailKey))
                    }
                }
                if notifier.blocked, settings.noticeRules.usesSystem {
                    LabeledContent(tr("noticeDelivery.blocked")) {
                        Button(tr("noticeDelivery.openSettings")) { SystemNotifier.openSystemSettings() }
                    }
                }
                SettingToggle(tr("agentNotice.watching"), detail: tr("agentNotice.watchingDetail"),
                              isOn: $settings.quietWhileWatching)
            } header: {
                Text(tr("notices.settings.how"))
            } footer: {
                Text(tr("notices.settings.howFooter"))
            }
            .onAppear { if settings.noticeRules.usesSystem { notifier.requestAccess() } }

            appSection(.agents, header: tr("notices.settings.agents"), footer: tr("notices.settings.agentsFooter"),
                       apps: AgentKind.allCases.map { AppRow(id: $0.rawValue, name: $0.name, icon: $0.rawValue, symbol: "terminal") })
            appSection(.chats, header: tr("notices.settings.chats"), footer: tr("notices.settings.chatsFooter"),
                       apps: capture.sources.apps.map {
                           AppRow(id: $0.id, name: $0.name, icon: $0.id, domain: $0.site, symbol: "bubble.left.fill")
                       })
            if !thinkAlong.mutedApps.isEmpty {
                appSection(.suggestions, header: tr("notices.settings.suggestions"), footer: tr("notices.settings.suggestionsFooter"),
                           apps: thinkAlong.mutedApps.sorted { $0.value < $1.value }.map {
                               AppRow(id: $0.key, name: $0.value, icon: nil, symbol: "app.dashed")
                           })
            }
        }
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
    private func appSection(_ source: NoticeSource, header: String, footer: String, apps: [AppRow]) -> some View {
        Section {
            ForEach(apps) { row in
                Toggle(isOn: isOn(source, app: row.id)) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        SiteIcon(domain: row.domain, fallback: row.symbol, tint: NookTheme.textSecondary, size: 20, source: row.icon)
                            .frame(width: 22)
                        Text(row.name)
                    }
                }
            }
        } header: {
            Text(header)
        } footer: {
            Text(footer)
        }
        .disabled(settings.noticeRules.style(for: source) == .off)
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
