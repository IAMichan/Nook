import AppKit
import SwiftUI

/// While a call you started from a chat goes on: a small card at the bottom right of the screen with who it is with,
/// how long it lasts, and the microphone, sound output and camera it uses, as `RecordingBadge` shows a recording. It
/// never takes the focus, and shows with the notch on or off.
@MainActor
final class ChatCallBadge {
    static let shared = ChatCallBadge()
    private var panel: NSPanel?
    private static let size = NSSize(width: 300, height: 178)

    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        if panel.contentView == nil {
            panel.contentView = NSHostingView(rootView: ChatCallBadgeView(center: ChatCallCenter.shared))
        }
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        // Above the Notetaker's badge, which sits in the corner itself.
        panel.setFrame(NSRect(x: frame.maxX - Self.size.width - 16, y: frame.minY + 68,
                              width: Self.size.width, height: Self.size.height), display: true)
        panel.orderFrontRegardless()
    }

    /// The content goes with the card, so a hidden card keeps no clock running.
    func hide() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}

private struct ChatCallBadgeView: View {
    @ObservedObject var center: ChatCallCenter

    var body: some View {
        if let call = center.call {
            // perf: a clock of the call's own, once a second, only while the card shows.
            TimelineView(.nookTicks(every: 1)) { context in
                card(call, now: context.date)
            }
        }
    }

    private func card(_ call: ChatCallCenter.Call, now: Date) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                ChatsFace(entry: call.entry, size: 34)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(call.entry.name)
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(tr(call.kind == .video ? "chats.call.video" : "chats.call.voice") + " · " + call.appName)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: NookTheme.Spacing.xs)
                status(call, now: now)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                device("mic.fill", tr("chats.call.microphone"), center.devices.microphone ?? tr("chats.call.unknownDevice"))
                device("speaker.wave.2.fill", tr("chats.call.speaker"), center.devices.speaker ?? tr("chats.call.unknownDevice"))
                device(center.devices.camera == nil ? "video.slash.fill" : "video.fill", tr("chats.call.camera"),
                       center.devices.camera ?? tr("chats.call.cameraOff"))
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if case .calling = call.tracker.phase, !call.direct {
                    Text(tr("chats.call.pressInApp", call.appName))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: NookTheme.Spacing.xs)
                SmallGhostButton(title: tr("chats.call.hide")) { center.dismiss() }
                SmallPrimaryButton(title: tr("chats.openApp", call.appName)) { center.showApp() }
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NookTheme.shape(NookTheme.Radius.panel).fill(NookTheme.canvas.opacity(0.96)))
        .overlay(NookTheme.shape(NookTheme.Radius.panel).strokeBorder(NookTheme.line2))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func status(_ call: ChatCallCenter.Call, now: Date) -> some View {
        switch call.tracker.phase {
        case .calling:
            stamp(tr("chats.call.calling"), ChatCallTracker.clock(now.timeIntervalSince(call.tracker.started)), NookTheme.amber)
        case .live(let since):
            stamp(tr("chats.call.live"), ChatCallTracker.clock(now.timeIntervalSince(since)), NookTheme.mint)
        case .ended(let duration, _):
            stamp(tr("chats.call.ended"), ChatCallTracker.clock(duration), NookTheme.textTertiary)
        }
    }

    private func stamp(_ label: String, _ clock: String, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: NookTheme.Spacing.xxs) {
            Text(clock)
                .font(NookTheme.TextStyle.strong.monospacedDigit())
                .foregroundStyle(NookTheme.paper)
            Text(label)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private func device(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Image(icon: symbol)
                .font(NookTheme.font(10, .semibold))
                .foregroundStyle(NookTheme.textTertiary)
                .frame(width: 14)
            Text(label)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
            Spacer(minLength: NookTheme.Spacing.xs)
            Text(value)
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}
