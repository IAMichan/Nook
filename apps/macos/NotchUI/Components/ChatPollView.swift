import SwiftUI

/// A poll in a chat bubble, the same in every chat: its question, each option with a bar for its share of the votes and
/// how many chose it, and your own choice ticked. Where the app names the voters, "View votes" lists them under each
/// option, as WhatsApp does. With `onVote` a click on an option votes (in a poll of one answer it replaces your choice,
/// a second click takes it back); without, the poll says to vote in the app. Drawn by `ChatTranscript`; never draw a
/// poll by hand.
struct ChatPollView: View {
    static let width: CGFloat = 260

    let poll: ChatPoll
    let onVote: (([String]) -> Void)?
    /// Your vote shows at once, before the app confirms it.
    @State private var pending: ChatPoll?
    /// Who chose what shows under each option.
    @State private var showVoters = false

    private var shown: ChatPoll { pending ?? poll }
    /// Counts where they are known, also the ones Nook saw itself when earlier votes may be missing.
    private var showsCounts: Bool { shown.counted || shown.partial }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.xs) {
                Image(systemName: "chart.bar.fill")
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                    .accessibilityHidden(true)
                Text(shown.question)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !shown.options.isEmpty {
                Text(shown.multiple ? tr("chat.poll.many") : tr("chat.poll.one"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
            }
            ForEach(shown.options) { option in
                row(option)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                // Counts only where they are known: a poll found later has its votes in the app.
                if showsCounts, !shown.options.isEmpty {
                    Text(tr("chat.poll.votes", shown.total))
                }
                if shown.namesVoters {
                    Button {
                        withAnimation(NookTheme.reveal) { showVoters.toggle() }
                    } label: {
                        Text(showVoters ? tr("chat.poll.hideVotes") : tr("chat.poll.viewVotes"))
                            .foregroundStyle(NookTheme.blue)
                    }
                    .buttonStyle(.plain)
                }
                if onVote == nil {
                    Spacer(minLength: NookTheme.Spacing.sm)
                    Text(tr("chat.poll.inApp"))
                }
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
            if shown.partial {
                Text(tr("chat.poll.partial"))
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .onChange(of: poll) { _, _ in pending = nil }
    }

    private func row(_ option: ChatPoll.Option) -> some View {
        let share = shown.total == 0 ? 0 : CGFloat(option.votes) / CGFloat(shown.total)
        return Button {
            guard let onVote else { return }
            let choice = shown.choice(afterTapping: option.text)
            withAnimation(NookTheme.swap) { pending = shown.voting(choice) }
            onVote(choice)
        } label: {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Image(systemName: option.chosen ? "checkmark.circle.fill" : (shown.multiple ? "square" : "circle"))
                        .font(NookTheme.font(13))
                        .foregroundStyle(option.chosen ? NookTheme.mint : NookTheme.textSecondary)
                    Text(option.text)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    if showsCounts {
                        Text("\(option.votes)")
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(NookTheme.textSecondary)
                            .monospacedDigit()
                    }
                }
                if showsCounts {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(NookTheme.line2)
                            Capsule().fill(option.chosen ? NookTheme.mint : NookTheme.textSecondary)
                                .frame(width: geometry.size.width * share)
                        }
                    }
                    .frame(height: 4)
                }
                if showVoters, let voters = option.voters, !voters.isEmpty {
                    Text(voters.joined(separator: ", "))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onVote == nil)
        .accessibilityLabel(accessibilityLabel(option))
        .accessibilityAddTraits(option.chosen ? .isSelected : [])
    }

    /// The option, how many chose it and who, for VoiceOver.
    private func accessibilityLabel(_ option: ChatPoll.Option) -> String {
        guard showsCounts else { return option.text }
        let voters = (option.voters ?? []).joined(separator: ", ")
        return [option.text, tr("chat.poll.votes", option.votes), voters].filter { !$0.isEmpty }.joined(separator: ", ")
    }
}
