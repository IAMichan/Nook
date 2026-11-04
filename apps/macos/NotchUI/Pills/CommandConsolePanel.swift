import SwiftUI
import AppKit

/// Which command the Terminal tab shows: the session Nook runs, and the command's event in its timeline.
struct CommandConsoleRef: Equatable {
    let run: UUID
    let event: UUID
}

/// The command a `CommandConsoleRef` points to, read again as the agent streams its output: the timeline changes only
/// through `WorkspaceManager.timelines`, so this view observes it and the workbench around it does not redraw.
/// It stays on that command when the agent starts the next one, so you can read its output; the bar offers the newer one.
struct LiveCommandConsole: View {
    @ObservedObject var timelines: TimelineChanges
    let workspace: WorkspaceManager
    let console: CommandConsoleRef
    let show: (UUID) -> Void
    let close: () -> Void

    var body: some View {
        let timeline = workspace.timeline(console.run)
        if let event = timeline.first(where: { $0.id == console.event }) {
            let newer = CommandConsole.running(timeline).flatMap { $0.id == console.event ? nil : $0.id }
            CommandConsolePanel(event: event, showNewer: newer.map { id in { show(id) } }, close: close)
        } else {
            // The session no longer has the command: back to your own shells.
            Color.clear.onAppear(perform: close)
        }
    }
}

/// A command the agent runs, in the Terminal tab of the session's side panel: the command and its output as it comes
/// in, as you would see it in a shell. Opens from the live "Running a command" line; closing it shows your own shells.
/// A newer command does not replace it by itself: the bar offers it (`showNewer`).
struct CommandConsolePanel: View {
    let event: RunEvent
    /// Goes to the command the agent runs now, when that is another one than this.
    var showNewer: (() -> Void)? = nil
    let close: () -> Void

    private var command: String { CommandConsole.commandLine(event) }
    private var output: String { CommandConsole.output(event.output) }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            toolbar
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                            Text("$").foregroundStyle(NookTheme.mint)
                            Text(command).foregroundStyle(NookTheme.paper)
                        }
                        .font(NookTheme.mono(11.5, .medium))
                        if output.isEmpty {
                            Text(tr(event.state == .running ? "ws.console.waiting" : "ws.console.noOutput"))
                                .font(NookTheme.TextStyle.detail)
                                .foregroundStyle(NookTheme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(output)
                                .font(NookTheme.mono(11.5))
                                .foregroundStyle(event.state == .failed ? NookTheme.coralSoft : NookTheme.textSecondary)
                        }
                        if event.state == .running {
                            BlinkingCursor()
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: event.output?.count ?? 0) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: event.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The bar under the Terminal tab (`SidePanelToolbar`), where your shells have their folder bar: how the command
    /// is doing, copy, and back to your shells.
    private var toolbar: some View {
        SidePanelToolbar {
            status
            Spacer(minLength: NookTheme.Spacing.md)
            if let showNewer {
                SmallGhostButton(title: tr("ws.console.newer"), action: showNewer)
                    .help(tr("ws.console.newer.help"))
            }
            CopyIconButton(tr("ws.console.copy")) { "$ " + command + (output.isEmpty ? "" : "\n" + output) }
            SidePanelCloseButton(help: tr("ws.console.close"), action: close)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch event.state {
        case .running:
            HStack(spacing: 5) {
                SpinningRing(color: NookTheme.textSecondary).frame(width: 10, height: 10)
                Text(tr("ws.console.running"))
            }
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
        case .failed:
            Label(tr("ws.console.failed"), systemImage: "xmark")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coralSoft)
        default:
            Label(tr("ws.console.done"), systemImage: "checkmark")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.mint)
        }
    }
}

/// The block cursor of a shell that still runs.
private struct BlinkingCursor: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.nookTicks(every: 0.55)) { context in
            let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate / 0.55) % 2 == 0
            Rectangle()
                .fill(NookTheme.textSecondary)
                .frame(width: 7, height: 13)
                .opacity(on ? 1 : 0)
        }
        .accessibilityHidden(true)
    }
}
