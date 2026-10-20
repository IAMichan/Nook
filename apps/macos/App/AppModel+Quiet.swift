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
            Task { @MainActor in self?.quietTick() }
        }
        // A changed choice applies right away, not on the next tick.
        settings.$quietWhileSharing.map { _ in () }
            .merge(with: settings.$quietInMeetings.map { _ in () }, settings.$quietUseCalendar.map { _ in () },
                   settings.$hideFromCaptures.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.quietTick() }
            .store(in: &bag)
    }

    /// Reads what is going on and, when that or your choice changed, tells the notch and the sounds.
    func quietTick() {
        let situation = demoMode
            ? QuietSituation()
            : QuietWatch.situation(events: upcoming, useCalendar: settings.quietUseCalendar, recording: NoteTaker.shared.isRecording)
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
