import SwiftUI
import AppKit

/// A command the agent runs, in the Terminal tab of the session's side panel: the command and its output as it comes
/// in, as you would see it in a shell. Opens from the live "Running a command" line; closing it shows your own shells.
struct CommandConsolePanel: View {
    let event: RunEvent
    let close: () -> Void
    @State private var copied = false

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
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", tr("ws.console.copy")) {
                Pasteboard.copy("$ " + command + (output.isEmpty ? "" : "\n" + output))
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            }
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
