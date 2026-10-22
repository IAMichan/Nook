import SwiftUI
import AppKit

// A single message in a Nook conversation, with its error card, typing indicator and offer chips.

struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    /// The latest finished answer: the only one you can retry.
    var isLast = false
    /// The newest message: a question at its end can be answered with a click.
    var isNewest = false
    /// Used for the buttons only, deliberately not observed: observing the whole app model redrew every message on
    /// every change anywhere in Nook.
    let app: AppModel
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: user
        case .nook: nook
        }
    }

    private var user: some View {
        VStack(alignment: .trailing, spacing: NookTheme.Spacing.sm) {
            if !message.images.isEmpty {
                ImageMessageRow(images: message.images)
            }
            if !message.text.isEmpty {
                ConversationMessage(fromUser: true, text: message.text, size: 14)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var nook: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            if message.isError {
                ChatErrorCard(message: message, canRetry: isLast)
            } else if !message.text.isEmpty {
                ConversationMessage(fromUser: false, text: message.text, size: 14,
                                    onChoose: !message.streaming && isNewest ? { app.handleUserText($0) } : nil)
            } else if message.streaming && message.charts.isEmpty && message.mails.isEmpty {
                TypingIndicator(status: message.status, since: message.date)
            }

            ForEach(message.charts) { chart in
                ChatChartView(chart: chart)
            }

            ForEach(message.mails) { mail in
                MailDraftView(
                    draft: mail,
                    onSend: { app.sendMail($0) },
                    onOpen: { app.openMail($0) }
                )
                .id(mail.id)
            }

            if !message.streaming && !message.visibleNotices.isEmpty {
                NoticeList(notices: message.visibleNotices)
            }

            // Where Nook looked, folded away until you want to see it; a source that failed opens it.
            if !message.isError {
                SourcesDisclosure(message: message, onRetry: isLast ? { app.retryLast() } : nil)
            }

            if !message.actions.isEmpty {
                PlanReview(message: message)
            }

            // What Nook can do next: one click to execute.
            // Stacked when they do not fit side by side, so a long offer is never cut off.
            if !message.streaming && !message.offers.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NookTheme.Spacing.sm) { offerChips }
                    VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) { offerChips }
                }
            }

            if message.streaming && !message.text.isEmpty && !message.status.isEmpty {
                TypingIndicator(status: message.status, since: message.date)
            }

            if !message.streaming && !message.isError && !message.text.isEmpty {
                actionRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var offerChips: some View {
        ForEach(message.offers, id: \.self) { offer in
            OfferChip(text: offer) { app.handleUserText(offer) }
        }
    }

    /// Under a finished answer, on hover: copy, try again (the newest answer only) and when it was written. The row keeps
    /// its place when hidden, so nothing jumps when the pointer moves over the thread.
    private var actionRow: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", copied ? tr("button.copied") : tr("button.copy"), height: 22) {
                Pasteboard.copy(message.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            if isLast {
                ToolbarIconButton("arrow.clockwise", tr("chat.retry"), height: 22) { app.retryLast() }
            }
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.leading, NookTheme.Spacing.xs)
        }
        .opacity(hovering || copied ? 1 : 0)
        .animation(NookTheme.hover, value: hovering)
        .padding(.top, -NookTheme.Spacing.sm)
        .padding(.leading, -NookTheme.Spacing.sm)
    }

    static func == (a: ChatMessageView, b: ChatMessageView) -> Bool {
        a.message.id == b.message.id && a.message.revision == b.message.revision && a.isLast == b.isLast && a.isNewest == b.isNewest
    }
}

/// A calm card for an answer that could not be made: what happened in plain words, the action that fixes it, retry as the
/// second choice, and the raw message behind Details.
private struct ChatErrorCard: View {
    let message: ChatMessage
    let canRetry: Bool
    @EnvironmentObject private var app: AppModel
    @State private var showDetails = false

    private var recovery: ChatRecoveryAction { ChatRecoveryAction.forError(message.text, selection: app.settings.selection) }

    private var explanation: String {
        switch recovery {
        case .chooseModel: return tr("chat.error.chooseModel")
        case .openLocalServer(let runtime): return tr("chat.error.server", runtime == .ollama ? "Ollama" : "LM Studio")
        case .reconnectBrain, .reconnectConnection: return tr("chat.error.credentials")
        case .openSettings: return tr("chat.error.generic")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(NookTheme.font(14, .semibold))
                    .foregroundStyle(NookTheme.coralSoft)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(tr("chat.error.title"))
                        .font(NookTheme.TextStyle.strong)
                        .foregroundStyle(NookTheme.paper)
                    Text(explanation)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The fix first, try again second, and the raw message tucked behind Details.
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                HStack(spacing: NookTheme.Spacing.xs) {
                    SmallPrimaryButton(title: app.recoveryTitle(recovery)) { app.performRecovery(recovery) }
                    if canRetry {
                        SmallGhostButton(title: tr("chat.retry")) { app.retryLast() }
                    }
                }
                Button { withAnimation(NookTheme.reveal) { showDetails.toggle() } } label: {
                    Text(showDetails ? tr("chat.error.hideDetails") : tr("chat.error.details"))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textTertiary)
                }
                .buttonStyle(.plain)
                if showDetails {
                    Text(message.text)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(NookTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control, style: .continuous).fill(NookTheme.well))
                }
            }
            .padding(.leading, 26)
        }
        .padding(NookTheme.Spacing.lg)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.panel, style: .continuous).fill(NookTheme.coral.opacity(0.07)))
    }
}

/// What Nook is doing right now, as an agent session shows it: a pulsing dot, the current step shimmering, and how long
/// the answer has been going.
private struct TypingIndicator: View {
    let status: String
    /// When the answer started.
    var since: Date? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var label: String { status.isEmpty ? tr("chat.thinking") : status }

    var body: some View {
        HStack(spacing: 8) {
            PulseDot(color: NookTheme.iris, animated: !reduceMotion)
                .frame(width: 14, height: 14)
            Group {
                if reduceMotion {
                    Text(label).foregroundStyle(NookTheme.textSecondary)
                } else {
                    ShimmerText(text: label)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(since)
                    // Only once it takes a moment: a quick answer should not flash a timer.
                    if elapsed >= 3 {
                        Text(AgentPathFormat.duration(elapsed))
                            .foregroundStyle(NookTheme.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(NookTheme.TextStyle.detail)
        .padding(.vertical, NookTheme.Spacing.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }
}

/// A next step Nook offers under its answer: one click asks it.
private struct OfferChip: View {
    let text: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: NookTheme.Spacing.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .font(NookTheme.font(10, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                Text(text)
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                    .lineLimit(1)
            }
            .padding(.horizontal, NookTheme.Spacing.lg)
            .frame(height: 28)
            .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.field))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(NookTheme.hover, value: hovering)
        .accessibilityLabel("Nook: \(text)")
    }
}

/// A conversation as Markdown, to paste elsewhere: who said what, in order.
enum ChatExport {
    static func markdown(_ conversation: Conversation) -> String {
        var parts = ["# " + conversation.title]
        for message in conversation.messages where !message.text.isEmpty {
            let author = message.role == .user ? tr("chat.you") : "Nook"
            parts.append("**\(author)**\n\n" + message.text)
        }
        return parts.joined(separator: "\n\n")
    }
}
