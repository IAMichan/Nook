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
        if state != quiet { quiet = state }
        notch.applyQuiet(state, alwaysExcluded: settings.hideFromCaptures)
        NookSound.muted = state.silent
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
