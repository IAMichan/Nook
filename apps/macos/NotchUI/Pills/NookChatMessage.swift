import SwiftUI
import AppKit

// A single message in a Nook conversation, on the shared `TranscriptUserMessage` and `TranscriptReply`, with its
// error card, typing indicator and offer chips.

struct ChatMessageView: View, Equatable {
    let message: ChatMessage
    /// The latest finished answer: the only one you can retry.
    var isLast = false
    /// The newest message: a question at its end can be answered with a click.
    var isNewest = false
    /// Used for the buttons only, deliberately not observed: observing the whole app model redrew every message on
    /// every change anywhere in Nook.
    let app: AppModel
    /// Where a picked option or offer is asked; nil asks in the chat on screen. The card beside a selection asks in its
    /// own conversation (`SelectionAskCard`).
    var onAsk: ((String) -> Void)? = nil

    private func ask(_ text: String) {
        if let onAsk { onAsk(text) } else { app.handleUserText(text) }
    }

    var body: some View {
        switch message.role {
        case .user: user
        case .nook: nook
        }
    }

    /// What you wrote: the same message as in an agent's conversation (`TranscriptUserMessage`), with its pictures.
    private var user: some View {
        TranscriptUserMessage(text: message.text, date: message.date) {
            if !message.images.isEmpty {
                ImageMessageRow(images: message.images)
            }
        }
    }

    /// Nook's answer: the same reply as an agent's (`TranscriptReply`), with what came with it (a chart, a mail, its
    /// sources, a plan, what Nook can do next) under the words, and copy, try again and the time on hover.
    @ViewBuilder
    private var nook: some View {
        if message.isError {
            ChatErrorCard(message: message, canRetry: isLast)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TranscriptReply(text: message.text, date: message.date, footer: !message.streaming,
                            onChoose: !message.streaming && isNewest ? { ask($0) } : nil) {
                extras
            } actions: {
                if isLast {
                    ToolbarIconButton("arrow.clockwise", tr("chat.retry"), height: 22) { app.retryLast() }
                }
            }
            // Its citations are raised numbers that open their source, as in the notch's card (`NookAnswerView`).
            .answerReferences(message.references)
        }
    }

    @ViewBuilder
    private var extras: some View {
        // The plan Nook works through, the same checklist an agent session shows.
        if !message.tasks.isEmpty {
            TaskChecklistCard(steps: planSteps)
        }

        if message.text.isEmpty && message.streaming && message.charts.isEmpty && message.mails.isEmpty {
            TypingIndicator(status: message.status, since: message.date)
        }

        ForEach(message.charts) { chart in
            ChatChartView(chart: chart)
        }

        ForEach(message.mails) { mail in
            MailDraftView(
                draft: mail,
                onSend: { app.sendMail($0) },
                onOpen: { app.openMail($0) },
                onDismiss: { app.dismissMail($0) },
                onReopen: { app.reopenMail($0) }
            )
            .id(mail.id)
        }

        if !message.streaming && !message.visibleNotices.isEmpty {
            NoticeList(notices: message.visibleNotices)
        }

        if !message.privateBrief.isEmpty {
            PrivateBriefDisclosure(brief: message.privateBrief)
        }

        // The sources the answer cites, right under it as chips that open them, as in the notch's card
        // (`NookAnswerView`): where a fact comes from is one click away without opening the details.
        if !message.streaming {
            let cited = NookAnswer(text: message.text, references: message.references).cited
            if !cited.isEmpty {
                AnswerSourceChips(references: cited)
            }
        }

        // Where Nook looked, folded away after every answer until you want to see it; a failed source shows as a badge.
        SourcesDisclosure(message: message, onRetry: isLast ? { app.retryLast() } : nil)

        if !message.actions.isEmpty {
            PlanReview(message: message)
        }

        // What Nook can do next: one click to execute, the same chips as in the notch's card.
        if !message.streaming && !message.offers.isEmpty {
            AnswerOfferChips(offers: message.offers) { ask($0) }
        }

        if message.streaming && !message.text.isEmpty && !message.status.isEmpty {
            TypingIndicator(status: message.status, since: message.date)
        }
    }

    /// Once the answer stops, nothing runs any more: a step the brain left in progress reads as not done, not spinning.
    private var planSteps: [RunTaskStep] {
        guard !message.streaming else { return message.tasks }
        return message.tasks.map { $0.status == .active ? RunTaskStep(text: $0.text, status: .pending) : $0 }
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
                Image(icon: "exclamationmark.circle.fill")
                    .font(NookTheme.font(13, .semibold))
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
                .buttonStyle(.nookPlain)
                if showDetails {
                    Text(message.text)
                        .font(NookTheme.mono(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(NookTheme.Spacing.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .roundedBackground(NookTheme.well, radius: NookTheme.Radius.control)
                }
            }
            .padding(.leading, 26)
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.coral.opacity(0.07), radius: NookTheme.Radius.panel)
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
                TimelineView(.nookTicks(every: 1)) { context in
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
