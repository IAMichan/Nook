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
        VStack(alignment: .trailing, spacing: 6) {
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
        VStack(alignment: .leading, spacing: 10) {
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
            if !message.streaming && !message.offers.isEmpty {
                HStack(spacing: 6) {
                    ForEach(message.offers, id: \.self) { offer in
                        OfferChip(text: offer) { app.handleUserText(offer) }
                    }
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

    /// Under a finished answer, on hover: copy, try again (the newest answer only) and when it was written. The row keeps
    /// its place when hidden, so nothing jumps when the pointer moves over the thread.
    private var actionRow: some View {
        HStack(spacing: 2) {
            ToolbarIconButton(copied ? "checkmark" : "doc.on.doc", copied ? tr("button.copied") : tr("button.copy"), height: 22) {
                Pasteboard.copy(message.text)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }
            if isLast {
                ToolbarIconButton("arrow.clockwise", tr("chat.retry"), height: 22) { app.retryLast() }
            }
            Text(message.date.formatted(date: .omitted, time: .shortened))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .padding(.leading, 4)
        }
        .opacity(hovering || copied ? 1 : 0)
        .animation(NookTheme.hover, value: hovering)
        .padding(.top, -4)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark")
                    .font(NookTheme.font(10, .bold))
                    .foregroundStyle(NookTheme.coralSoft)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(NookTheme.coral.opacity(0.14)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("chat.error.title"))
                        .font(NookTheme.font(13.5, .semibold))
                        .foregroundStyle(NookTheme.paper)
                    Text(explanation)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 6) {
                Button { app.performRecovery(recovery) } label: {
                    Text(app.recoveryTitle(recovery))
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.ink)
                        .padding(.horizontal, 13)
                        .frame(height: 28)
                        .background(Capsule().fill(NookTheme.paper))
                }
                .buttonStyle(.plain)
                if canRetry {
                    Button { app.retryLast() } label: {
                        Text(tr("chat.retry"))
                            .font(NookTheme.font(12, .semibold))
                            .foregroundStyle(NookTheme.paper)
                            .padding(.horizontal, 13)
                            .frame(height: 28)
                            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 32)
            Button { withAnimation(NookTheme.reveal) { showDetails.toggle() } } label: {
                Text(showDetails ? tr("chat.error.hideDetails") : tr("chat.error.details"))
                    .font(NookTheme.TextStyle.label)
                    .foregroundStyle(NookTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 32)
            if showDetails {
                Text(message.text)
                    .font(NookTheme.mono(11))
                    .foregroundStyle(NookTheme.textTertiary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: NookTheme.Radius.control).fill(NookTheme.field))
                    .padding(.leading, 32)
            }
        }
        .padding(12)
        .cardBackground(NookTheme.coral.opacity(0.06), stroke: NookTheme.coral.opacity(0.22), radius: NookTheme.Radius.sheet, style: .continuous)
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
        .font(NookTheme.font(12.5))
        .padding(.vertical, 4)
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
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.down.right")
                    .font(NookTheme.font(9.5, .semibold))
                    .foregroundStyle(NookTheme.textTertiary)
                Text(text)
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? NookTheme.smoke : Color.clear))
            .overlay(Capsule().stroke(NookTheme.line2, lineWidth: 1))
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
