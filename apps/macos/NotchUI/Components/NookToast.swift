import SwiftUI

/// What a toast reports. The color keeps its meaning: mint is done, coral an error, amber waits on you, iris is Nook.
enum NookToastKind: Equatable {
    case success
    case error
    case warning
    case info

    var color: Color {
        switch self {
        case .success: return NookTheme.mint
        case .error: return NookTheme.coral
        case .warning: return NookTheme.amber
        case .info: return NookTheme.iris
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    /// How long it stays by itself: an error is read more slowly than a confirmation.
    var duration: TimeInterval {
        switch self {
        case .success, .info: return 3
        case .warning: return 5
        case .error: return 6
        }
    }
}

/// One short message: a title, an optional line under it, and its kind.
struct NookToast: Identifiable, Equatable {
    let id = UUID()
    let kind: NookToastKind
    let title: String
    var detail: String?
    var duration: TimeInterval
}

/// The one place any part of Nook reports a short result: "Saved", "Couldn't connect", "Approved". Every surface with a
/// `.nookToastHost()` (the panel in the notch and the main window, Settings) shows the current toast at its bottom edge.
/// Toasts wait their turn; the same title twice in a row only restarts the timer.
///
///     ToastCenter.shared.success(tr("settings.saved"))
///     ToastCenter.shared.error(error)
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: NookToast?
    private var queue: [NookToast] = []
    private var timer: Task<Void, Never>?
    /// While the pointer is on the toast it stays; it closes a moment after the pointer leaves.
    private var paused = false

    /// Shows a toast; `duration` nil uses the kind's own.
    func show(_ title: String, detail: String? = nil, kind: NookToastKind = .info, duration: TimeInterval? = nil) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let toast = NookToast(kind: kind, title: title, detail: detail?.nilIfBlank, duration: duration ?? kind.duration)
        if let current, current.kind == toast.kind, current.title == toast.title, current.detail == toast.detail {
            schedule(current)
            return
        }
        guard !queue.contains(where: { $0.kind == toast.kind && $0.title == toast.title && $0.detail == toast.detail }) else { return }
        if current == nil { present(toast) } else { queue.append(toast) }
    }

    func success(_ title: String, detail: String? = nil) { show(title, detail: detail, kind: .success) }
    func warning(_ title: String, detail: String? = nil) { show(title, detail: detail, kind: .warning) }
    func info(_ title: String, detail: String? = nil) { show(title, detail: detail, kind: .info) }
    func error(_ title: String, detail: String? = nil) { show(title, detail: detail, kind: .error) }

    /// An error as Nook says it: its localized description under `title` (or as the title when there is none).
    func error(_ error: Error, title: String? = nil) {
        let message = error.localizedDescription
        if let title { show(title, detail: message, kind: .error) } else { show(message, kind: .error) }
    }

    /// Closes the current toast and shows the next one waiting.
    func dismiss() {
        timer?.cancel()
        timer = nil
        paused = false
        withAnimation(NookTheme.close) { current = nil }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        // Let the old one leave before the next comes in.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            self?.present(next)
        }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused {
            timer?.cancel()
        } else if let current {
            schedule(current, after: 1.5)
        }
    }

    private func present(_ toast: NookToast) {
        withAnimation(NookTheme.open) { current = toast }
        schedule(toast)
    }

    private func schedule(_ toast: NookToast, after delay: TimeInterval? = nil) {
        timer?.cancel()
        guard !paused else { return }
        let id = toast.id
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay ?? toast.duration))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.dismiss()
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

/// The toast itself: the kind's symbol, the title and its line, and a close button.
struct NookToastView: View {
    let toast: NookToast
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
            Image(systemName: toast.kind.symbol)
                .font(NookTheme.font(13, .semibold))
                .foregroundStyle(toast.kind.color)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(toast.title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = toast.detail {
                    Text(detail)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            ToolbarIconButton("xmark", tr("toast.dismiss"), height: 18, close)
        }
        .padding(.leading, NookTheme.Spacing.lg)
        .padding(.trailing, NookTheme.Spacing.xs)
        .padding(.vertical, NookTheme.Spacing.md)
        .frame(maxWidth: 420, alignment: .leading)
        .cardBackground(NookTheme.surface, stroke: toast.kind.color.opacity(0.3), radius: NookTheme.Radius.card, style: .continuous)
        .shadow(color: NookTheme.notch.opacity(0.45), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// Shows `ToastCenter`'s current toast over the bottom edge of this view.
private struct NookToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = center.current {
                NookToastView(toast: toast) { center.dismiss() }
                    .onHover { center.setPaused($0) }
                    .padding(.horizontal, NookTheme.Spacing.xl)
                    .padding(.bottom, NookTheme.Spacing.xl)
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                    .onAppear {
                        // VoiceOver reads the toast without having to find it.
                        let text = [toast.title, toast.detail].compactMap { $0 }.joined(separator: ". ")
                        AccessibilityNotification.Announcement(text).post()
                    }
            }
        }
    }
}

extension View {
    /// Lets this surface show Nook's toasts (see `ToastCenter`). Add it once at the root of a window or panel.
    func nookToastHost() -> some View {
        modifier(NookToastHost())
    }
}
