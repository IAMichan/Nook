import SwiftUI
import AppKit

/// Settings › Overview: what still needs doing and how each part of Nook is doing. Each switch and shortcut lives on its
/// own page only.
extension SettingsView {
    // MARK: Overview

    struct Step: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var done: Bool
        var button: String
        var section: SettingsSection
        /// Permission request run in place; nil means the button navigates to `section`.
        var request: (@MainActor () async -> Void)? = nil
    }

    var checklist: [Step] {
        let _ = refreshTick
        let _ = settings.appLanguage
        return [
            Step(title: tr("settings.checklist.brain"), detail: settings.brainReady ? tr("settings.checklist.brain.ready", settings.activeModelName) : tr("settings.checklist.brain.notReady"),
                 done: settings.brainReady, button: tr("button.choose"), section: .brain),
            Step(title: tr("settings.checklist.screen"), detail: permissions.isGranted(.screen) ? tr("settings.checklist.screen.granted") : tr("settings.checklist.screen.notGranted"),
                 done: permissions.isGranted(.screen), button: tr("button.allow"), section: .privacy,
                 request: { await permissions.request(.screen, app: app) }),
            Step(title: tr("settings.checklist.calendar"), detail: permissions.isGranted(.calendar) ? tr("settings.checklist.calendar.granted") : tr("settings.checklist.calendar.notGranted"),
                 done: permissions.isGranted(.calendar), button: tr("button.allow"), section: .privacy,
                 request: { await permissions.request(.calendar, app: app) }),
            Step(title: tr("settings.checklist.connectors"), detail: tr("settings.checklist.connectors.detail", app.connectors.active.count),
                 done: app.connectors.active.count >= 1, button: tr("button.view"), section: .connections)
        ]
    }

    /// One thing that needs you, wherever it lives in Settings, with the one button that deals with it.
    struct AttentionItem: Identifiable {
        var id: String
        var title: String
        var detail: String
        var state: StatusState
        var button: String
        var action: () -> Void
    }

    /// Everything that needs you, in one list: the setup steps still open, connections that stopped working, agent links
    /// that are out of date, and completing when it is missing something. The Overview shows it, the sidebar counts it.
    /// `problems` is `ConnectionProblems.current(app)`, which the body works out once per redraw.
    func attention(problems: [ConnectionProblems.Problem]) -> [AttentionItem] {
        var items = checklist.filter { !$0.done }.map { step in
            AttentionItem(id: "step." + step.title, title: step.title, detail: step.detail, state: .todo, button: step.button) {
                if let request = step.request {
                    app.requestPermission { await request(); refreshTick += 1 }
                } else {
                    app.settingsSection = step.section
                }
            }
        }
        items += problems.map { problem in
            AttentionItem(id: "connection." + problem.id, title: problem.title, detail: problem.detail, state: problem.state,
                          button: tr("settings2.fix")) { app.settingsSection = problem.isChat ? .chats : .connections }
        }
        let outdated = AgentConfigInstaller.Target.allCases.filter {
            if case .outdated? = agentStates[$0] { return true }
            return false
        }
        items += outdated.map { target in
            AttentionItem(id: "agent.\(target)", title: target.title, detail: tr("agents.status.outdated"), state: .warning,
                          button: tr("button.updateEllipsis")) { prepare(target, install: true) }
        }
        if AutocompleteController.shared.needsAttention {
            items.append(AttentionItem(id: "autocomplete", title: SettingsSection.autocomplete.title,
                                       detail: tr("hub.overview.autocomplete"), state: .warning,
                                       button: tr("button.view")) { app.settingsSection = .autocomplete })
        }
        return items
    }

    /// `items` is `attention(problems:)` and `problems` the number of services (not chat apps) that stopped working.
    func startSection(attention items: [AttentionItem], problems: Int) -> some View {
        Group {
            // One list of what needs you, from every page; once it is empty a single calm line says so.
            Section {
                if items.isEmpty {
                    StatusRow(title: tr("hub.overview.allGood"), detail: tr("hub.overview.allGoodDetail"), state: .done) {
                        EmptyView()
                    }
                }
                ForEach(items) { item in
                    StatusRow(title: item.title, detail: item.detail, state: item.state) {
                        Button(item.button, action: item.action)
                            .buttonStyle(.nookProminent)
                            .controlSize(.small)
                    }
                }
            } header: {
                HStack {
                    Text(tr("hub.overview.attention"))
                    Spacer()
                    Button(tr("settings.setup.open")) { app.startOnboarding() }
                        .buttonStyle(.nookLink)
                }
            }
            .onAppear { permissions.watch() }
            .onDisappear { permissions.unwatch() }
            Section {
                // One row per sidebar page that has something to report, in the sidebar's order.
                glanceRow(.brain, detail: settings.brainReady ? settings.activeModelName : tr("settings.checklist.brain.notReady"),
                          state: settings.brainReady ? .done : .todo)
                TypingGlanceRow()
                glanceRow(.agents, detail: tr("settings.start.agentsLinked", linkedAgentCount), state: linkedAgentCount > 0 ? .done : .todo)
                AutomationGlanceRow()
                let chats = chatsGlance
                glanceRow(.chats, detail: chats.text, state: chats.state)
                let connections = connectionsGlance(broken: problems)
                glanceRow(.connections, detail: connections.text, state: connections.state)
                IPhoneGlanceRow()
                let granted = SystemPermission.allCases.count(where: { permissions.isGranted($0) })
                // Only the recommended permissions make this a to-do; the optional ones (contacts, the microphone…) never do.
                let recommendedGranted = SystemPermission.allCases.allSatisfy { !$0.isRecommended || permissions.isGranted($0) }
                glanceRow(.permissions, detail: tr("settings.start.permissions", granted, SystemPermission.allCases.count),
                          state: recommendedGranted ? .done : .todo)
                UpdateGlanceRow()
            } header: {
                SettingText("settings.start.glance")
            }
        }
    }

    /// One line per part of Nook: its tile, how it is doing, and a way to go there. What works stays quiet; only what
    /// still needs you shows a symbol.
    func glanceRow(_ section: SettingsSection, detail: String, state: StatusState) -> some View {
        OverviewGlanceRow(section: section, detail: detail, state: state)
    }

    /// The chat apps linked, by name, and how many need a new sign-in.
    var chatsGlance: (text: String, state: StatusState) {
        let linked = ChatAppStates.all().filter(\.linked)
        if linked.isEmpty { return (tr("settings.start.chats.none"), .todo) }
        let broken = linked.count(where: { $0.status == .expired || $0.status == .unreachable })
        if broken > 0 { return (tr("settings.start.connectionsBroken", linked.count, broken), .warning) }
        return (tr("settings.start.chats.linked", linked.count, linked.map(\.name).joined(separator: ", ")), .done)
    }

    /// Active sources, and how many need a new sign-in.
    func connectionsGlance(broken: Int) -> (text: String, state: StatusState) {
        let active = app.connectors.active.count
        if broken > 0 { return (tr("settings.start.connectionsBroken", active, broken), .warning) }
        return (tr("settings.checklist.connectors.detail", active), active > 0 ? .done : .todo)
    }

    /// Agents whose link with Nook is in place.
    var linkedAgentCount: Int {
        agentStates.values.filter { state in
            if case .installed = state { return true }
            return false
        }.count
    }
}

/// One line on the Overview: a page's tile and name, how it is doing, and a way to go there.
private struct OverviewGlanceRow: View {
    @EnvironmentObject private var app: AppModel
    let section: SettingsSection
    let detail: String
    let state: StatusState

    var body: some View {
        // Pages that hold more than one subject go by their page name ("Typing", not "Autocomplete").
        SettingsLinkRow(title: section.pageTitle, detail: detail, section: section, state: state) {
            app.openSettings(section: section)
        }
    }
}

/// Typing: off, on with what it typed today, or on but missing what it needs.
private struct TypingGlanceRow: View {
    @ObservedObject private var store = AutocompleteStore.shared
    @ObservedObject private var autocomplete = AutocompleteController.shared

    var body: some View {
        let status = self.status
        OverviewGlanceRow(section: .autocomplete, detail: status.text, state: status.state)
    }

    private var status: (text: String, state: StatusState) {
        guard store.prefs.enabled else { return (tr("settings.start.off"), .done) }
        if autocomplete.needsAttention { return (tr("hub.overview.autocomplete"), .warning) }
        let words = store.stats.day().words
        return (words > 0 ? tr("settings.start.typing.today", words) : tr("settings.start.on"), .done)
    }
}

/// Automation: how many scheduled tasks are on, when the next one runs, and whether one failed last time.
private struct AutomationGlanceRow: View {
    @ObservedObject private var store = ScheduledTaskStore.shared

    var body: some View {
        let status = self.status
        OverviewGlanceRow(section: .automation, detail: status.text, state: status.state)
    }

    private var status: (text: String, state: StatusState) {
        let on = store.tasks.filter(\.enabled)
        if on.isEmpty { return (tr("settings.start.automation.none"), .done) }
        let failed = on.count(where: { $0.lastStatus == .failed })
        if failed > 0 { return (tr("settings.start.automation.failed", on.count, failed), .warning) }
        if let next = on.compactMap(\.nextRun).min() {
            return (tr("settings.start.automation.next", on.count, next.formatted(.relative(presentation: .named))), .done)
        }
        return (tr("settings.start.automation.on", on.count), .done)
    }
}

/// iPhone: off, nothing paired yet, or the paired phones and when one was last seen.
private struct IPhoneGlanceRow: View {
    @ObservedObject private var store = CompanionStore.shared

    var body: some View {
        let status = self.status
        OverviewGlanceRow(section: .iphone, detail: status.text, state: status.state)
    }

    private var status: (text: String, state: StatusState) {
        guard store.enabled else { return (tr("settings.start.off"), .done) }
        guard let latest = store.devices.max(by: { ($0.lastSeen ?? .distantPast) < ($1.lastSeen ?? .distantPast) }) else {
            return (tr("settings.start.iphone.none"), .todo)
        }
        let names = store.devices.map(\.name).joined(separator: ", ")
        let seen = latest.lastSeen.map { tr("companion.lastSeen", $0.formatted(.relative(presentation: .named))) }
        let outdated = store.devices.contains { $0.protocolVersion != nil && !CompanionCompatibility.phoneSupported($0.protocolVersion) }
        if outdated { return ([names, tr("pairedPhone.outdated")].joined(separator: " · "), .warning) }
        return ([names, seen].compactMap { $0 }.joined(separator: " · "), .done)
    }
}

/// Maintenance: which version this is and whether a newer one is waiting.
private struct UpdateGlanceRow: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        let status = self.status
        OverviewGlanceRow(section: .maintenance, detail: status.text, state: status.state)
    }

    private var status: (text: String, state: StatusState) {
        switch updater.phase {
        case .available:
            if let release = updater.releaseUpdate {
                return (tr("update.release.status.available", release.version.description), .warning)
            }
            return (tr("update.settings.status.available", updater.available?.count ?? 0), .warning)
        case .installing: return (tr("update.installing.title"), .done)
        case .readyToRestart: return (tr("update.ready.title"), .warning)
        case .readyToBuildInXcode: return (tr("update.xcode.title"), .warning)
        case .failed: return (tr("update.failed.title"), .error)
        case .checking: return (tr("update.settings.status.checking"), .done)
        case .upToDate: return (tr("update.settings.status.upToDate"), .done)
        case .idle, .unavailable:
            if updater.checkProblem != nil { return (tr("update.settings.status.problem"), .warning) }
            return (tr("update.settings.status.never"), .done)
        }
    }
}
