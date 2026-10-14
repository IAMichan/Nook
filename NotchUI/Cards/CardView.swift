import SwiftUI

/// De vaste opbouw van elke kaart: context, één zin, hooguit één detailregel en hooguit twee knoppen.
struct CardView: View {
    let card: NookCard
    let onAction: (CardAction) -> Void
    let onVoice: () -> Void
    var onReply: (String) -> Void = { _ in }

    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(card.context)
                .font(NookTheme.font(12, .medium))
                .foregroundStyle(NookTheme.textTertiary)

            Text(card.title)
                .font(NookTheme.font(18, .semibold))
                .foregroundStyle(NookTheme.paper)
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)

            detail
                .padding(.top, 14)

            Spacer(minLength: 12)

            if card.input { replyField.padding(.bottom, 10) }

            HStack(spacing: 4) {
                NookPrimaryButton(title: card.primary.label) { onAction(card.primary) }
                if !card.secondary.label.isEmpty {
                    NookGhostButton(title: card.secondary.label) { onAction(card.secondary) }
                }
                Spacer()
                NookIconButton(systemName: "mic", label: "Aanpassen met je stem", action: onVoice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand { onAction(card.primary) }
    }

    /// Doorvragen met tekst: altijd klaar om te typen, Enter verstuurt.
    private var replyField: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $reply,
                prompt: Text("Vraag door of reageer…").foregroundStyle(NookTheme.textTertiary)
            )
            .textFieldStyle(.plain)
            .font(NookTheme.font(14))
            .foregroundStyle(NookTheme.paper)
            .focused($replyFocused)
            .onSubmit {
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                reply = ""
                onReply(text)
            }
            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NookTheme.textTertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(Capsule().fill(NookTheme.field))
        .onAppear {
            // Even wachten tot het paneel de toetsenbordfocus heeft gekregen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { replyFocused = true }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch card.detail {
        case .none:
            EmptyView()
        case .event(let top, let big, let line, let subline):
            EventDetail(top: top, big: big, line: line, subline: subline)
        case .command(let command, let note):
            CommandDetail(command: command, note: note)
        case .waveform:
            WaveformDetail()
        case .steps(let steps):
            StepsDetail(steps: steps)
        }
    }
}

// MARK: Detailregels

private struct EventDetail: View {
    let top: String
    let big: String
    let line: String
    let subline: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(top)
                    .font(NookTheme.font(9, .semibold))
                    .foregroundStyle(NookTheme.textSecondary)
                Text(big)
                    .font(NookTheme.font(14, .bold))
                    .foregroundStyle(NookTheme.paper)
            }
            .frame(width: 36, height: 36)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(NookTheme.line2, lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(line)
                    .font(NookTheme.font(14, .medium))
                    .foregroundStyle(NookTheme.paper)
                Text(subline)
                    .font(NookTheme.font(12.5))
                    .foregroundStyle(NookTheme.textSecondary)
            }
        }
    }
}

private struct CommandDetail: View {
    let command: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text("$ ").foregroundStyle(NookTheme.textTertiary)
                Text(command).foregroundStyle(NookTheme.paper).lineLimit(2)
            }
            .font(NookTheme.mono(13.5))
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { Rectangle().fill(NookTheme.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(NookTheme.line).frame(height: 1) }

            Text(note)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textSecondary)
        }
    }
}

private struct WaveformDetail: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<18, id: \.self) { i in
                    let wave = abs(sin(t * 5.7 + Double(i) * 0.55))
                    Capsule()
                        .fill(NookTheme.mint)
                        .frame(width: 3, height: 5 + 21 * CGFloat(wave))
                }
            }
            .frame(height: 28)
        }
        .accessibilityHidden(true)
    }
}

private struct StepsDetail: View {
    let steps: [PlanStep]

    private func color(_ tone: StepTone) -> Color {
        switch tone {
        case .good: return NookTheme.mint
        case .neutral: return NookTheme.textSecondary
        case .caution: return NookTheme.amber
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 12) {
                    Text("\(step.number)")
                        .font(NookTheme.font(11, .bold))
                        .foregroundStyle(color(step.tone))
                        .frame(width: 20, height: 20)
                        .overlay(Circle().stroke(color(step.tone), lineWidth: 1.5))
                    Text(step.text)
                        .font(NookTheme.font(14))
                        .foregroundStyle(NookTheme.paper)
                    if !step.tag.isEmpty {
                        Text(step.tag)
                            .font(NookTheme.font(12, .medium))
                            .foregroundStyle(color(step.tone))
                    }
                }
            }
        }
    }
}
