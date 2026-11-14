import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// What the home screen shows (Today) and the Settings window.
extension AppModel {
    /// Asked several times per redraw of the panel (the tabs' count, Nook's ring and mood): made again only when a list it
    /// comes from changed. An unchanged list is the same array, which compares at once.
    var agentSessions: [AgentSession] {
        if demoMode { return DemoContent.agents }
        if let cache = agentSessionsCache, cache.runs == workspace.runs, cache.sessions == hub.sessions,
           cache.detected == hub.detected {
            return cache.value
        }
        let value = makeAgentSessions()
        agentSessionsCache = (workspace.runs, hub.sessions, hub.detected, value)
        return value
    }

    private func makeAgentSessions() -> [AgentSession] {
        // A chat you continued in Nook is listed once, as the Nook session, not also as the session its app reported.
        let runs = workspace.runs.filter { !$0.archived }.compactMap { run -> (agent: String, conversations: Set<String>)? in
            guard let current = run.providerSessionID, !current.isEmpty else { return nil }
            return (run.provider.displayName, Set([current] + run.earlierConversations))
        }
        let hooked = runs.isEmpty ? hub.sessions : hub.sessions.filter { session in
            let needsYou = session.status == .waiting || session.approvalID != nil
            return !AgentSessionRegistry.isContinuedInNook(agent: session.name, conversation: session.ownConversationID,
                                                           needsYou: needsYou, runs: runs)
        }
        return hooked + hub.detected
    }

    /// Connected agents actively working or awaiting approval/input.
    var activeAgents: [AgentSession] {
        agentSessions.filter {
            guard !$0.isDetected, $0.status == .running || $0.status == .waiting || $0.approvalID != nil else { return false }
            // A chat you marked as finished is not busy, even if its turn still hangs; it only counts when it needs you.
            return $0.status == .waiting || $0.approvalID != nil || !isSettledWhileBusy($0)
        }
    }

    /// What Today shows: everything that may need you as one list, ranked by `AttentionScorer` (an approval before a
    /// question, a question before a reply you owe, what is due soon before what is not, and what you tend to act on
    /// before what you keep turning away). The phone's home shows the same rows.
    var todayItems: [TodayItem] {
        if demoMode { return DemoContent.today }
        let now = Date()
        var items: [RankedTodayItem] = []

        // Proactive offer from Nook awaiting user reaction.
        if let missed = missedNudge, now.timeIntervalSince(missed.date) < 45 * 60 {
            items.append(RankedTodayItem(
                attention: AttentionItem(source: NoticeSource.suggestions.rawValue, id: "nudge-\(missed.card.id)", app: missed.app,
                                         needsYou: .info, since: missed.date),
                row: TodayItem(
                    id: "nudge-\(missed.card.id)",
                    title: missed.line,
                    subtitle: tr("app.today.alongIn", missed.app, NookDates.time(missed.date)),
                    action: tr("button.view"),
                    color: NookTheme.iris,
                    target: .action { [weak self] in
                        self?.missedNudge = nil
                        self?.viewModel.show(.card(missed.card))
                    },
                    logo: .symbol("sparkles")
                )))
        }

        if let attention = autocompleteAttentionItem() {
            items.append(RankedTodayItem(attention: AttentionItem(source: "autocomplete", id: attention.id, needsYou: .failure),
                                         row: attention))
        }

        // Agents that wait on you or failed, owed replies and birthdays.
        items += agentAttention(now: now)
        items += owedChatAttention(now: now)
        items += birthdayAttention(now: now)

        if let next = upcoming.first(where: { $0.end > now }), next.start.timeIntervalSince(now) < 3 * 3600 {
            let starting = next.start <= now
            items.append(RankedTodayItem(
                attention: AttentionItem(source: "calendar", id: "event-\(next.id)", subject: next.id, needsYou: .info,
                                         deadline: next.start),
                row: TodayItem(
                    id: "event-\(next.id)",
                    title: next.title,
                    subtitle: (starting ? tr("app.today.now") : tr("app.today.at", NookDates.time(next.start))) + (next.location.isEmpty ? "" : " · \(next.location)"),
                    action: tr("app.today.prepare"),
                    color: NookTheme.iris,
                    target: .action { [weak self] in
                        self?.handleUserText(tr("app.today.preparePrompt", next.title))
                    },
                    logo: .source("calendar")
                )))
        }

        for source in connectors.needingAttention.prefix(2) {
            items.append(RankedTodayItem(
                attention: AttentionItem(source: "connectors", id: "connector-\(source.id)", app: source.id, needsYou: .failure),
                row: TodayItem(
                    id: "connector-\(source.id)",
                    title: "\(source.title): \(source.status.headline)",
                    subtitle: source.status.detail.isEmpty ? (source.status.items.first?.title ?? "") : source.status.detail,
                    action: tr("button.view"),
                    color: NookTheme.amber,
                    target: .action { [weak self] in self?.openSettings(section: .connections) },
                    logo: .source(source.id)
                )))
        }

        if let recapItem = weeklyRecapItem() {
            items.append(RankedTodayItem(attention: AttentionItem(source: "nook", id: recapItem.id, needsYou: .info), row: recapItem))
        }

        for loop in loops.prefix(3) {
            items.append(RankedTodayItem(
                attention: AttentionItem(source: "loops", id: "loop-\(loop.id)", subject: loop.id, needsYou: .info, since: loop.created),
                row: TodayItem(
                    id: "loop-\(loop.id)",
                    title: loop.title,
                    subtitle: tr("app.today.openSince", NookDates.short(loop.created, locale: NookDates.appLocale)),
                    action: tr("app.today.finish"),
                    color: NookTheme.amber,
                    target: .action { [weak self] in self?.presentLoop(loop) },
                    logo: .symbol("checklist")
                )))
        }
        var shown = attentionScorer(now: now).rank(items, by: \.attention).prefix(5).map(\.row)
        // What autocomplete saved you today: last, and only when there is room.
        if shown.count < 5, let used = autocompleteTodayItem() { shown.append(used) }
        return shown
    }

    func reloadLoops() {
        loops = store.openLoops()
    }

    func refreshUpcoming() async {
        guard calendar.hasEventAccess else { return }
        let now = Date()
        let events = await calendar.loadEvents(from: now, to: now.addingTimeInterval(36 * 3600))
        // Every five minutes, and usually the same meetings: publishing them again would redraw every view of the app.
        if events != upcoming { upcoming = events }
    }


    /// Settings › Projects on one project, as a project folder's menu in the Agents list opens it.
    func openProjectSettings(_ path: String) {
        settingsProjectScope = path
        openSettings(section: .projects)
    }

    /// Custom window: standard Settings scene does not open reliably in an accessory app.
    func openSettings(section: SettingsSection? = nil, highlight key: String? = nil) {
        if let section { settingsSection = section }
        SettingsHighlight.shared.key = key
        // Floating notch panel overlays all windows; dismiss it so clicks reach Settings.
        if case .panel = viewModel.state { viewModel.show(.idle) }
        if settingsWindow == nil {
            // Kept after closing, so its content goes while it is closed: else Settings redraws with every change in the app.
            let root = WindowContent(presence: settingsPresence, background: NookTheme.canvas, minSize: CGSize(width: 720, height: 480)) {
                SettingsView().nookToastHost()
            }
            let host = NSHostingController(rootView: root.nookAttention().environmentObject(self))
            // The window sets its own minSize: letting the hosting view drive it measured the whole Form on every update.
            host.sizingOptions = []
            let window = NSWindow(contentViewController: host)
            window.title = "Nook"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            // The appearance and canvas from Settings › Appearance, not whatever the Mac's wallpaper gives.
            NookWindowLook.adopt(window)
            window.setContentSize(SettingsLayout.openingSize(on: NSScreen.main))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            settingsPresence.follow(window)
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settingsPresence.shown = false }
            }
            settingsWindow = window
        }
        settingsPresence.shown = true
        if let settingsWindow { DockPresence.shared.track(settingsWindow) }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Runs a system permission request from Settings. The macOS prompt takes focus and,
    /// as an accessory app, Settings would sink behind other windows; bring it back afterwards.
    func requestPermission(_ request: @escaping @MainActor () async -> Void) {
        Task { @MainActor in
            await request()
            // Nook just opened System Settings for this permission: the user has to flip the switch there.
            if let opened = PermissionMonitor.shared.openedSettings, Date().timeIntervalSince(opened) < 3 { return }
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }
}
