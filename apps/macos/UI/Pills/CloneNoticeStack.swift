import SwiftUI

/// The clones running in the background (`CloneCenter`), each a quiet notice in the panel's top-right corner, over the
/// toasts: which repository, how far git is, and Hide and Cancel. Hide only takes the notice away; the clone goes on and
/// its toast still comes. Its own view, so a clone's progress redraws these notices and nothing else of the panel.
struct CloneNoticeStack: View {
    @ObservedObject private var center = CloneCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = center.shown
        VStack(alignment: .trailing, spacing: NookTheme.Spacing.md) {
            ForEach(shown) { job in
                PanelNoticeBar(title: tr("clone.running", job.name),
                               detail: job.cancelling ? tr("clone.cancelling") : (job.progress?.summary ?? tr("clone.starting")),
                               symbol: "arrow.down.circle", tone: NookTheme.iris, help: job.url,
                               actions: [
                                   NookNoticeAction(tr("clone.hide")) { center.hide(job.id) },
                                   NookNoticeAction(tr("button.cancel")) { center.cancel(job.id) },
                               ],
                               floating: true) {
                    EmptyView()
                }
                .transition(.nookToast(reduceMotion: reduceMotion))
            }
        }
        .animation(NookTheme.reveal, value: shown.map(\.id))
    }
}
