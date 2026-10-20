import AppKit
import SwiftUI

/// While the Notetaker records: a small capsule at the bottom right of the screen with the time and a Stop button, so
/// you always see that a call is being noted. It never takes the focus.
@MainActor
final class RecordingBadge {
    static let shared = RecordingBadge()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? make()
        self.panel = panel
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let size = NSSize(width: 210, height: 44)
        panel.setFrame(NSRect(x: frame.maxX - size.width - 16, y: frame.minY + 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 210, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingBadgeView(notes: NoteTaker.shared))
        return panel
    }
}

private struct RecordingBadgeView: View {
    @ObservedObject var notes: NoteTaker

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Circle()
                    .fill(NookTheme.coral)
                    .frame(width: 9, height: 9)
                    .opacity(0.55 + 0.45 * Double(min(1, notes.level * 12)))
                Text(elapsed(at: context.date))
                    .font(NookTheme.font(12, .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Text(tr("notes.badge.recording"))
                    .font(NookTheme.font(12))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 4)
                Button(tr("notes.badge.stop")) { notes.stop() }
                    .buttonStyle(.plain)
                    .font(NookTheme.font(12, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let start = notes.current?.start else { return "0:00" }
        return NoteBuilder.clock(date.timeIntervalSince(start))
    }
}
