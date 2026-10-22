import SwiftUI

/// A poll in a chat bubble, the same in every chat: its question, each option with a bar for its share of the votes and
/// how many chose it, and your own choice ticked. With `onVote` a click on an option votes (in a poll of one answer it
/// replaces your choice, a second click takes it back); without, the poll says to vote in the app. Drawn by
/// `ChatTranscript`; never draw a poll by hand.
struct ChatPollView: View {
    static let width: CGFloat = 260

    let poll: ChatPoll
    let onVote: (([String]) -> Void)?
    /// Your vote shows at once, before the app confirms it.
    @State private var pending: ChatPoll?

    private var shown: ChatPoll { pending ?? poll }

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
            Text(shown.multiple ? tr("chat.poll.many") : tr("chat.poll.one"))
                .font(NookTheme.TextStyle.caption)
                .foregroundStyle(NookTheme.textTertiary)
            ForEach(shown.options) { option in
                row(option)
            }
            HStack {
                Text(tr("chat.poll.votes", shown.total))
                if onVote == nil {
                    Spacer(minLength: NookTheme.Spacing.sm)
                    Text(tr("chat.poll.inApp"))
                }
            }
            .font(NookTheme.TextStyle.caption)
            .foregroundStyle(NookTheme.textTertiary)
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
                    Image(systemName: option.chosen ? "checkmark.circle.fill" : (shown.multiple ? "square" : "circle"))
                        .font(NookTheme.font(13))
                        .foregroundStyle(option.chosen ? NookTheme.mint : NookTheme.textSecondary)
                    Text(option.text)
                        .font(NookTheme.font(13.5))
                        .foregroundStyle(NookTheme.paper)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NookTheme.Spacing.sm)
                    Text("\(option.votes)")
                        .font(NookTheme.font(12, .medium))
                        .foregroundStyle(NookTheme.textSecondary)
                        .monospacedDigit()
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(NookTheme.line2)
                        Capsule().fill(option.chosen ? NookTheme.mint : NookTheme.textSecondary)
                            .frame(width: geometry.size.width * share)
                    }
                }
                .frame(height: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onVote == nil)
        .accessibilityLabel("\(option.text), \(tr("chat.poll.votes", option.votes))")
        .accessibilityAddTraits(option.chosen ? .isSelected : [])
    }
}
