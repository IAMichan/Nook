import SwiftUI
import Combine
import AppKit

/// Meetings and screen sharing: every few seconds Nook looks whether you share your screen or sit in a meeting
/// (`QuietWatch`) and behaves the way you chose in Settings › Notifications (`QuietPolicy`): as usual, quiet, left out of
/// what you share, or hidden until it is over.
extension AppModel {
    func startQuietWatch() {
        quietTick()
        Timer.scheduledCoalesced(withTimeInterval: 2) { [weak self] _ in
            Task { @MainActor in self?.quietTimerTick() }
        }
        // A changed choice applies right away, not on the next tick.
        settings.$quietWhileSharing.map { _ in () }
            .merge(with: settings.$quietInMeetings.map { _ in () }, settings.$quietUseCalendar.map { _ in () },
                   settings.$hideFromCaptures.map { _ in () }, settings.$showInScreenshots.map { _ in () })
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

    /// The timer's tick: every two seconds while it matters. With only the meeting choice in play it is slower while you are
    /// away or the Mac saves power; a choice for screen sharing keeps the two seconds, so a share that starts never shows
    /// Nook to the viewers for longer than that. A changed choice still applies right away (`startQuietWatch`).
    private func quietTimerTick() {
        guard quietWatchNeeded else {
            // Nook was still quiet or hidden for a choice you just changed to "change nothing": one more read puts it back.
            if quiet.silent || quiet.excludedFromCapture || quiet.hidden { quietTick() }
            return
        }
        // A sleeping display shares nothing and shows no meeting: reading every window then is for no one. The tick after
        // it wakes reads again.
        if EnergyMonitor.shared.plan.reasons.contains(.displayAsleep) { return }
        let interval = settings.quietWhileSharing == .normal ? 2 * EnergyMonitor.shared.plan.slowdown : 2
        guard Date().timeIntervalSince(lastQuietTick) >= interval - 0.5 else { return }
        quietTick()
    }

    /// Reads what is going on and, when that or your choice changed, tells the notch and the sounds.
    func quietTick() {
        lastQuietTick = Date()
        let situation = demoMode
            ? QuietSituation()
            : QuietWatch.situation(events: upcoming, useCalendar: settings.quietUseCalendar, recording: NoteTaker.shared.isRecording,
                                   countScreenshots: !settings.showInScreenshots)
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
