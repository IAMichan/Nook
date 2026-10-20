import SwiftUI
import AppKit

/// The terminal on the left of a session's conversation: the command the agent runs and its output as it comes in,
/// as you would see it in a shell. Opens from the live "Running a command" line.
struct CommandConsolePanel: View {
    let event: RunEvent
    let close: () -> Void
    @State private var copied = false

    private var command: String { CommandConsole.commandLine(event) }
    private var output: String { CommandConsole.output(event.output) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("$").foregroundStyle(NookTheme.mint)
                            Text(command).foregroundStyle(NookTheme.paper)
                        }
                        .font(NookTheme.mono(11.5, .medium))
                        if output.isEmpty {
                            Text(tr(event.state == .running ? "ws.console.waiting" : "ws.console.noOutput"))
                                .font(NookTheme.font(11.5))
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
                    .padding(10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .cardBackground(NookTheme.notch, stroke: NookTheme.line2, radius: 10, style: .continuous)
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: event.output?.count ?? 0) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: event.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(NookTheme.font(11, .semibold)).foregroundStyle(NookTheme.textTertiary)
            Text(tr("ws.console.title")).font(NookTheme.font(13, .semibold)).foregroundStyle(NookTheme.paper)
            status
            Spacer(minLength: 4)
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", tr("ws.console.copy")) {
                Pasteboard.copy("$ " + command + (output.isEmpty ? "" : "\n" + output))
                copied = true
                Task { try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
            }
            ToolbarIconButton("xmark", tr("ws.console.close"), close)
        }
        .frame(height: 30)
    }

    @ViewBuilder
    private var status: some View {
        switch event.state {
        case .running:
            HStack(spacing: 5) {
                SpinningRing(color: NookTheme.textSecondary).frame(width: 10, height: 10)
                Text(tr("ws.console.running"))
            }
            .font(NookTheme.font(11.5))
            .foregroundStyle(NookTheme.textTertiary)
        case .failed:
            Label(tr("ws.console.failed"), systemImage: "xmark")
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.coralSoft)
        default:
            Label(tr("ws.console.done"), systemImage: "checkmark")
                .font(NookTheme.font(11.5))
                .foregroundStyle(NookTheme.mint)
        }
    }
}

/// The block cursor of a shell that still runs.
private struct BlinkingCursor: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(NookTheme.textSecondary)
            .frame(width: 7, height: 13)
            .opacity(on ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { on = false }
            }
            .accessibilityHidden(true)
    }
}
