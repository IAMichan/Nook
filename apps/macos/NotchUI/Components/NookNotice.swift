import SwiftUI

/// The one shape every short notice in Nook takes: the strips under the notch (a result, a suggestion, a moment), the
/// bar in the open panel and the toast. A mark in the notice's state color, the message and an optional line under it,
/// the notice's own actions, and at the end the OK with the countdown ring of the notice closing by itself.
///
/// A notice that closes by itself always has that OK (`countdown` set); one that waits for you (a permission request,
/// an agent's question, a task's Stop) has none, and its own actions decide. The surfaces only add their frame around
/// it (`PanelNoticeBar`, the toast's bubble, the strip's margins), so every notice reads as the same kind of thing.
struct NookNotice<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    /// The mark before the message; nil for none.
    var symbol: String? = nil
    var tone: Color = NookTheme.textSecondary
    /// The notice's own actions (View, Open, Stop), in the dark bar before the OK: the same in every notice.
    var actions: [NookNoticeAction] = []
    /// Seconds until the notice closes by itself: shows the OK with its ring. Nil: the notice waits for you.
    var countdown: TimeInterval? = nil
    /// The pointer is on the notice: the ring holds, as the notice's clock does (`NoticeClock`).
    var paused: Bool = false
    /// A new value starts the ring over (the same notice shown again); nil keeps it running as long as the notice shows.
    var restart: AnyHashable? = nil
    /// The title and its line wrap instead of staying on one line (a toast, which has room to grow).
    var wraps: Bool = false
    var onOK: () -> Void = {}
    /// What a notice that waits for you asks with (`NookNoticeActions`: Allow and Deny), or a small extra control
    /// (the toast's copy button). Plain actions go in `actions`.
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: wraps ? .top : .center, spacing: NookTheme.Spacing.md) {
            if let symbol {
                Image(systemName: symbol)
                    .font(NookTheme.font(13, .bold))
                    .foregroundStyle(tone)
                    .frame(width: 16)
                    .padding(.top, wraps ? 2 : 0)
            }
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(wraps ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: wraps)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(wraps ? 4 : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: wraps)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NookTheme.Spacing.xs) {
                trailing()
                NookNoticeEnd(actions: actions, countdown: countdown, paused: paused, restart: restart,
                              onOK: countdown == nil ? nil : onOK)
            }
            .fixedSize()
        }
        .accessibilityElement(children: .contain)
    }
}

extension NookNotice where Trailing == EmptyView {
    init(title: String, detail: String? = nil, symbol: String? = nil, tone: Color = NookTheme.textSecondary,
         actions: [NookNoticeAction] = [], countdown: TimeInterval? = nil, paused: Bool = false,
         restart: AnyHashable? = nil, wraps: Bool = false, onOK: @escaping () -> Void = {}) {
        self.init(title: title, detail: detail, symbol: symbol, tone: tone, actions: actions, countdown: countdown,
                  paused: paused, restart: restart, wraps: wraps, onOK: onOK) { EmptyView() }
    }
}

/// The end of every notice, short or large: the notice's own actions in one dark bar (`NookActionBar`), then the OK
/// that closes it at once, with the countdown ring of it closing by itself. `NookNotice` ends in it, and so do the
/// compact agent notice in the notch's own row and a card with an OK (`CardView`), so a notice's buttons look and
/// behave the same everywhere.
struct NookNoticeEnd: View {
    var actions: [NookNoticeAction] = []
    var title: String = tr("button.ok")
    /// Seconds until the notice closes by itself, as a ring on the OK; nil for an OK without a ring.
    var countdown: TimeInterval? = nil
    /// The pointer is on the notice: the ring holds, as the notice's clock does (`NoticeClock`).
    var paused: Bool = false
    /// A new value starts the ring over.
    var restart: AnyHashable? = nil
    var compact: Bool = true
    /// A fixed height for the bar and the OK, e.g. to fit inside the notch's own row; nil follows `compact`.
    var height: CGFloat? = nil
    var spacing: CGFloat = NookTheme.Spacing.sm
    /// What the OK does; nil: no OK, the notice waits for you and its actions decide.
    var onOK: (() -> Void)? = nil

    var body: some View {
        // The bar and the OK stand exactly as tall, side by side.
        let side = height ?? (compact ? 32 : 38)
        HStack(spacing: spacing) {
            if !actions.isEmpty {
                NookActionBar(actions: actions, compact: compact, height: side)
            }
            if let onOK {
                NookAcknowledgeButton(title: title, compact: compact, countdown: countdown, paused: paused,
                                      height: side, action: onOK)
                    .id(restart)
            }
        }
        .fixedSize()
    }
}

/// The clock of a notice that closes by itself. It runs while the pointer is off the notice and holds while it is on,
/// exactly like the countdown ring on the notice's OK, so the ring never runs out before or after the notice goes.
@MainActor
final class NoticeClock {
    /// Seconds still left, counted up to `since`.
    private var left: TimeInterval = 0
    /// When the clock last started running; nil while it holds.
    private var since: Date?
    private var task: Task<Void, Never>?
    private var expire: (() -> Void)?

    /// Starts over with `seconds`; `held` starts it holding (the pointer is already on the notice).
    func start(_ seconds: TimeInterval, held: Bool = false, expire: @escaping () -> Void) {
        cancel()
        left = seconds
        self.expire = expire
        if !held { resume() }
    }

    /// The pointer came onto the notice: the time left stays as it is.
    func hold() {
        guard let since else { return }
        task?.cancel()
        task = nil
        left = max(0, left - Date().timeIntervalSince(since))
        self.since = nil
    }

    /// The pointer left the notice: the rest of the time runs out.
    func resume() {
        guard since == nil, expire != nil else { return }
        since = Date()
        let wait = left
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard !Task.isCancelled, let self, let expire = self.expire else { return }
            self.cancel()
            expire()
        }
    }

    /// The notice went another way (OK, an action, something else took its place): nothing fires.
    func cancel() {
        task?.cancel()
        task = nil
        since = nil
        expire = nil
    }
}
