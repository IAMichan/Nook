import SwiftUI
import Combine
import AppKit

/// Meetings and screen sharing: every few seconds Nook looks whether you share your screen or sit in a meeting
/// (`QuietWatch`) and behaves the way you chose in Settings › Notifications (`QuietPolicy`): as usual, quiet, left out of
/// what you share, or hidden until it is over.
extension AppModel {
    func startQuietWatch() {
        adoptPhoneQuietHours()
        // The first read goes the timer's way (off the main thread, and only when it matters), so it does not hold up
        // Nook's start and the main window opening with it. Leaving Nook out of captures applies right away all the same.
        if quietWatchNeeded { quietTimerTick() } else { applyQuiet(QuietSituation()) }
        Timer.scheduledCoalesced(withTimeInterval: 2) { [weak self] _ in
            Task { @MainActor in self?.quietTimerTick() }
        }
        // A changed choice applies right away, not on the next tick. Each choice also sends its value as it is subscribed
        // to, which is not a change: those five go.
        settings.$quietWhileSharing.removeDuplicates().dropFirst().map { _ in () }
            .merge(with: settings.$quietInMeetings.removeDuplicates().dropFirst().map { _ in () },
                   settings.$quietUseCalendar.removeDuplicates().dropFirst().map { _ in () },
                   settings.$hideFromCaptures.removeDuplicates().dropFirst().map { _ in () },
                   settings.$showInScreenshots.removeDuplicates().dropFirst().map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.quietTick() }
            .store(in: &bag)
    }

    /// Whether what is going on matters right now: you chose to behave differently in a meeting or share, or Settings
    /// shows the line that says what Nook notices. With "change nothing" for both and Settings closed, the read (every
    /// window on screen, every app with the microphone open) would be for no one, so it is skipped.
    var quietWatchNeeded: Bool {
        settings.quietWhileSharing != .normal || settings.quietInMeetings != .normal || quietViewers > 0
    }

    /// The timer's tick: every two seconds while a choice for screen sharing is in play, so a share that starts never shows
    /// Nook to the viewers for longer than that; slower with only the meeting choice (`QuietPolicy.watchInterval`). Nothing
    /// is read while the display sleeps or the screen is locked, nor while you are away and nothing is going on: starting a
    /// share or a call takes a key or a click, and the first tick after it reads. The window list is only read while an
    /// app runs that can show a sharing bar. A changed choice still applies right away (`startQuietWatch`).
    private func quietTimerTick() {
        refreshAttention()
        guard quietWatchNeeded else {
            // Nook was still quiet or hidden for a choice you just changed to "change nothing": one more read puts it back.
            if quiet.silent || quiet.excludedFromCapture || quiet.hidden { quietTick() }
            return
        }
        // A sleeping display shares nothing and shows no meeting: reading every window then is for no one. The tick after
        // it wakes reads again.
        if EnergyMonitor.shared.plan.unseen { return }
        let interval = QuietPolicy.watchInterval(watchesSharing: settings.quietWhileSharing != .normal, settingsOpen: quietViewers > 0,
                                                 slowdown: EnergyMonitor.shared.plan.slowdown)
        guard Date().timeIntervalSince(lastQuietTick) >= interval - 0.5, !quietReading else { return }
        guard !demoMode else { return quietTick() }
        // Away with nothing going on: no share or call starts without input. Read straight from the event source, not the
        // energy plan's ten-second reading, so the first tick after a key or click reads. A share or meeting already going
        // on keeps being read, so its end is noticed.
        let calm = !quiet.situation.sharing && !quiet.situation.meeting
        if calm, quietViewers == 0, AttentionNow.shared.context.isAway { return }
        let sharingPossible = RunningAppsWatch.shared.canShowSharingBar
        // The read (every window on screen, every audio process) runs off the main thread, so a slow WindowServer or
        // coreaudiod never holds up the notch, or the keys and clicks autocomplete's event tap waits on.
        lastQuietTick = Date()
        quietReading = true
        let events = upcoming, useCalendar = settings.quietUseCalendar, recording = NoteTaker.shared.isRecording
        let countScreenshots = !settings.showInScreenshots
        let microphoneInterval = QuietPolicy.microphoneInterval * EnergyMonitor.shared.plan.slowdown
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let situation = QuietWatch.situation(events: events, useCalendar: useCalendar, recording: recording,
                                                 countScreenshots: countScreenshots, microphoneInterval: microphoneInterval,
                                                 sharingPossible: sharingPossible)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.quietReading = false
                    self.applyQuiet(situation)
                }
            }
        }
    }

    /// Reads what is going on and, when that or your choice changed, tells the notch and the sounds.
    func quietTick() {
        lastQuietTick = Date()
        let situation = demoMode
            ? QuietSituation()
            : QuietWatch.situation(events: upcoming, useCalendar: settings.quietUseCalendar, recording: NoteTaker.shared.isRecording,
                                   countScreenshots: !settings.showInScreenshots)
        applyQuiet(situation)
    }

    /// Behaves the way you chose for what is going on: tells the notch and the sounds when that or your choice changed.
    private func applyQuiet(_ situation: QuietSituation) {
        let state = QuietPolicy.state(for: situation, sharing: settings.quietWhileSharing, meeting: settings.quietInMeetings)
        let wasHidden = quiet.hidden
        if state != quiet { quiet = state }
        notch.applyQuiet(state, alwaysExcluded: settings.hideFromCaptures)
        NookSound.muted = state.silent
        // Viewers see no Nook at all: also not the main window or Settings, nor a window opened during the share.
        let sharing: NSWindow.SharingType = settings.hideFromCaptures || state.excludedFromCapture ? .none : .readOnly
        for window in NSApp.windows where window.sharingType != sharing { window.sharingType = sharing }
        if state.hidden != wasHidden { hideOtherWindows(state.hidden) }
    }

    /// Hidden for a share or meeting: Nook's other windows (the main window, Settings) go too, and come back when it is
    /// over. A window you open yourself in the meantime stays.
    private func hideOtherWindows(_ hide: Bool) {
        if hide {
            // Titled windows only: the menu bar icon and the notch's own popovers stay where they are.
            quietHiddenWindows = NSApp.windows.filter {
                $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NotchPanel) && $0.parent == nil && $0.sheetParent == nil
            }
            quietHiddenWindows.forEach { $0.orderOut(nil) }
        } else {
            quietHiddenWindows.forEach { $0.orderFront(nil) }
            quietHiddenWindows = []
        }
    }

    /// Quiet hours set for the phone before the Mac shared them become the Mac's (`NoticeRules.quietHours`), once.
    private func adoptPhoneQuietHours() {
        let adoptedKey = "noticeRules.quietHoursAdopted"
        let defaults = UserDefaults.standard
        var rules = settings.noticeRules
        if rules.adoptingQuietHours(CompanionStore.shared.push.quietHours, adopted: defaults.bool(forKey: adoptedKey)) {
            settings.noticeRules = rules
        }
        defaults.set(true, forKey: adoptedKey)
    }

    /// Refreshes the shared `AttentionContext`: the input and the lock, the app in front, an event going on in your
    /// calendar, the quiet hours and what quiet mode read last. A few cheap reads every two seconds; nothing is published,
    /// so no view redraws for it.
    func refreshAttention(now: Date = Date()) {
        let idle = SystemLoad.idleSeconds, locked = SystemLoad.isScreenLocked
        let front = NSWorkspace.shared.frontmostApplication
        let frontApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? "" : (front?.bundleIdentifier ?? "")
        let inEvent = QuietPolicy.inEvent(upcoming.map { QuietPolicy.Event(start: $0.start, end: $0.end) }, now: now)
        let quietHours = settings.noticeRules.quietHours?.contains(now) ?? false
        let recording = NoteTaker.shared.isRecording
        let situation = quiet.situation, silent = quiet.silent
        AttentionNow.shared.update { context in
            context = context.refreshed(idle: idle, locked: locked, frontApp: frontApp, at: now)
            context.inEvent = inEvent
            context.quietHours = quietHours
            context.recording = recording
            context.meeting = situation.meeting
            context.sharing = situation.sharing
            context.silent = silent
        }
    }

    /// The line in Settings that says what Nook notices right now.
    var quietStatusText: String {
        switch (quiet.situation.sharing, quiet.situation.meeting) {
        case (true, true): return tr("quiet.status.both")
        case (true, false): return tr("quiet.status.sharing")
        case (false, true): return tr("quiet.status.meeting")
        case (false, false): return tr("quiet.status.none")
        }
    }
}

/// Whether an app runs that can share your screen (`QuietPolicy.canShowSharingBar`), worked out again only when an app
/// starts or quits. Reading every app's name asks LaunchServices once per app, synchronously on the main thread: doing
/// that on every quiet tick (every two seconds) was a steady share of the main thread.
@MainActor
final class RunningAppsWatch {
    static let shared = RunningAppsWatch()
    private var cached: Bool?
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { RunningAppsWatch.shared.cached = nil }
            })
        }
    }

    var canShowSharingBar: Bool {
        if let cached { return cached }
        let answer = QuietPolicy.canShowSharingBar(runningApps: NSWorkspace.shared.runningApplications.map {
            ($0.localizedName ?? "", $0.bundleIdentifier ?? "")
        })
        cached = answer
        return answer
    }
}
