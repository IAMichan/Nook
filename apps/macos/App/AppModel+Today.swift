import SwiftUI
import Combine
import AppKit
import Carbon.HIToolbox
import NaturalLanguage

/// What the home screen shows (Today) and the Settings window.
extension AppModel {
    var agentSessions: [AgentSession] {
        demoMode ? DemoContent.agents : hub.sessions + hub.detected
    }

    /// Connected agents actively working or awaiting approval/input.
    var activeAgents: [AgentSession] {
        agentSessions.filter {
            guard !$0.isDetected, $0.status == .running || $0.status == .waiting || $0.approvalID != nil else { return false }
            // A chat you marked as finished is not busy, even if its turn still hangs; it only counts when it needs you.
            return $0.status == .waiting || $0.approvalID != nil || !isSettledWhileBusy($0)
        }
    }

    var todayItems: [TodayItem] {
        if demoMode { return DemoContent.today }
        var items: [TodayItem] = []

        // Proactive offer from Nook awaiting user reaction.
        if let missed = missedNudge, Date().timeIntervalSince(missed.date) < 45 * 60 {
            items.append(TodayItem(
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
            ))
        }

        if let attention = autocompleteAttentionItem() { items.append(attention) }

        for session in hub.sessions where session.status == .waiting || session.status == .failed {
            let title = session.status == .waiting ? tr("app.today.agentWaiting", session.name) : tr("app.today.agentFailed", session.name)
            items.append(TodayItem(
                id: "agent-\(session.id)",
                title: title,
                subtitle: session.project,
                action: tr("button.view"),
                color: session.status.color,
                target: .agent(session.id),
                logo: .agent(session.name)
            ))
        }

        let now = Date()
        if let next = upcoming.first(where: { $0.end > now }), next.start.timeIntervalSince(now) < 3 * 3600 {
            let starting = next.start <= now
            items.append(TodayItem(
                id: "event-\(next.id)",
                title: next.title,
                subtitle: (starting ? tr("app.today.now") : tr("app.today.at", NookDates.time(next.start))) + (next.location.isEmpty ? "" : " · \(next.location)"),
                action: tr("app.today.prepare"),
                color: NookTheme.iris,
                target: .action { [weak self] in
                    self?.handleUserText("Help me voorbereiden op mijn afspraak \"\(next.title)\": what do I need to know and what on my screen is relevant?")
                },
                logo: .source("calendar")
            ))
        }

        for source in connectors.needingAttention.prefix(2) {
            items.append(TodayItem(
                id: "connector-\(source.id)",
                title: "\(source.title): \(source.status.headline)",
                subtitle: source.status.detail.isEmpty ? (source.status.items.first?.title ?? "") : source.status.detail,
                action: tr("button.view"),
                color: NookTheme.amber,
                target: .action { [weak self] in self?.openSettings(section: .connections) },
                logo: .source(source.id)
            ))
        }

        if let recapItem = weeklyRecapItem() { items.append(recapItem) }

        for loop in loops.prefix(3) {
            items.append(TodayItem(
                id: "loop-\(loop.id)",
                title: loop.title,
                subtitle: tr("app.today.openSince", NookDates.short(loop.created)),
                action: tr("app.today.finish"),
                color: NookTheme.amber,
                target: .action { [weak self] in self?.presentLoop(loop) },
                logo: .symbol("checklist")
            ))
        }
        var shown = Array(items.prefix(5))
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
        upcoming = await calendar.loadEvents(from: now, to: now.addingTimeInterval(36 * 3600))
    }


    /// Custom window: standard Settings scene does not open reliably in an accessory app.
    func openSettings(section: SettingsSection? = nil) {
        if let section { settingsSection = section }
        // Floating notch panel overlays all windows; dismiss it so clicks reach Settings.
        if case .panel = viewModel.state { viewModel.show(.idle) }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(self))
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Nook"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            // Nook is dark everywhere: the same near-black as the panel, not whatever the Mac's appearance and wallpaper give.
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0E / 255, alpha: 1)
            window.setContentSize(NSSize(width: 820, height: 600))
            window.minSize = NSSize(width: 720, height: 480)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
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
