import SwiftUI

/// De vaste opbouw van elke kaart: context, één zin, hooguit één detailregel en hooguit twee knoppen.
struct CardView: View {
    let card: NookCard
    let onAction: (CardAction) -> Void
    let onVoice: () -> Void
    var onReply: (String) -> Void = { _ in }
    var onChoose: (String, [String]) -> Void = { _, _ in }

    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(card.context)
                    .font(NookTheme.font(12, .medium))
                    .foregroundStyle(NookTheme.textSecondary)
                    .lineLimit(1)
                if !card.sources.isEmpty {
                    ForEach(card.sources.prefix(5), id: \.self) { source in
                        Text(source)
                            .font(NookTheme.font(10.5, .medium))
                            .foregroundStyle(NookTheme.textSecondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(NookTheme.smoke))
                            .lineLimit(1)
                    }
                }
            }

            if card.input {
                // Lange antwoorden scrollen en zijn te selecteren; ze worden nooit afgekapt.
                ScrollView(showsIndicators: false) {
                    titleText.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            } else {
                titleText.padding(.top, 6)
            }

            detail
                .padding(.top, 14)

            Spacer(minLength: 12)

            if !card.offers.isEmpty { offerChips.padding(.bottom, 10) }

            if card.input { replyField.padding(.bottom, 10) }

            HStack(spacing: 4) {
                NookPrimaryButton(title: card.primary.label) { onAction(card.primary) }
                if !card.secondary.label.isEmpty {
                    NookGhostButton(title: card.secondary.label) { onAction(card.secondary) }
                }
                ForEach(Array(card.extra.enumerated()), id: \.offset) { _, action in
                    NookGhostButton(title: action.label) { onAction(action) }
                }
                Spacer()
                NookIconButton(systemName: "mic", label: tr("card.voiceAdjust"), action: onVoice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onExitCommand { onAction(card.escape ?? card.primary) }
    }

    /// Korte zinnen groot; een langer antwoord in leesbare tekst, met **vet**, *schuin* en links.
    private var titleText: some View {
        let long = card.title.count > 140
        return Text(Self.rich(card.title))
            .font(long ? NookTheme.font(15, .regular) : NookTheme.font(18, .semibold))
            .lineSpacing(long ? 3 : 0)
            .foregroundStyle(NookTheme.paper)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private static func rich(_ text: String) -> AttributedString {
        MarkdownBlock.inline(MarkdownBlock.clean(text))
    }

    /// Wat Nook hierna kan doen: één klik en hij gaat ermee aan de slag.
    private var offerChips: some View {
        HStack(spacing: 6) {
            ForEach(card.offers, id: \.self) { offer in
                OfferChip(title: offer) { onReply(offer) }
            }
            Spacer(minLength: 0)
        }
    }

    /// Doorvragen met tekst: altijd klaar om te typen, Enter verstuurt.
    private var replyField: some View {
        HStack(spacing: 10) {
            TextField(
                "",
                text: $reply,
                prompt: Text(tr("chat.followupPrompt")).foregroundStyle(NookTheme.textTertiary)
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
        case .choices(let set):
            ChoicesDetail(set: set) { labels in onChoose(set.id, labels) }
                .id(set.id)   // nieuwe vraag, nieuwe keuzes
        case .diff(let title, let lines, let note):
            DiffDetail(title: title, lines: lines, note: note)
        case .facts(let facts):
            FactsDetail(facts: facts)
        }
    }
}

// MARK: Detailregels

/// Een aanbod van Nook als knop, met een sterretje ervoor.
private struct OfferChip: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(NookTheme.iris)
                Text(title)
                    .font(NookTheme.font(12.5, .medium))
                    .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(hovering ? NookTheme.smoke : NookTheme.field))
            .overlay(Capsule().stroke(hovering ? NookTheme.iris.opacity(0.3) : NookTheme.line2, lineWidth: 1))
            .contentShape(Capsule())
            .scaleEffect(hovering ? 1.02 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("Nook: \(title)")
    }
}

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

/// De opties bij een vraag van een agent. Eén keuze: klikken is antwoorden. Meer keuzes: aanvinken en versturen.
private struct ChoicesDetail: View {
    let set: ChoiceSet
    let onChoose: ([String]) -> Void
    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(set.options) { option in
                ChoiceRow(option: option, multi: set.multiSelect, checked: selected.contains(option.label)) {
                    if set.multiSelect {
                        if selected.contains(option.label) { selected.remove(option.label) } else { selected.insert(option.label) }
                    } else {
                        onChoose([option.label])
                    }
                }
            }
            if set.multiSelect {
                HStack {
                    Spacer()
                    NookPrimaryButton(title: selected.isEmpty ? tr("chat.choices.choose") : tr("chat.choices.sendCount", selected.count)) {
                        guard !selected.isEmpty else { return }
                        // In de volgorde van de opties, niet van het klikken.
                        onChoose(set.options.map(\.label).filter { selected.contains($0) })
                    }
                    .opacity(selected.isEmpty ? 0.5 : 1)
                }
                .padding(.top, 4)
            }
        }
    }
}

private struct ChoiceRow: View {
    let option: ChoiceOption
    let multi: Bool
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: multi ? (checked ? "checkmark.square.fill" : "square") : "arrow.right.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(checked ? NookTheme.mint : NookTheme.textSecondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(NookTheme.font(14, .medium))
                        .foregroundStyle(NookTheme.paper)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(NookTheme.font(12))
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering || checked ? NookTheme.smoke : NookTheme.field))
            .contentShape(Rectangle())
            .scaleEffect(hovering ? 1.01 : 1)
            .animation(.spring(duration: 0.2, bounce: 0.1), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Een bewerking van een agent: bestandsnaam, de gewijzigde regels en een korte toelichting.
private struct DiffDetail: View {
    let title: String
    let lines: [DiffLine]
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(NookTheme.textTertiary).padding(.bottom, 4)
                    ForEach(lines) { line in
                        Text(line.text).foregroundStyle(line.color).lineLimit(1)
                    }
                }
                .font(NookTheme.mono(11.5))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0x0A0A0D)))

            Text(note)
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textSecondary)
        }
    }
}

/// Cijfers in twee kolommen, zoals het weekoverzicht.
private struct FactsDetail: View {
    let facts: [Fact]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
            ForEach(facts) { fact in
                VStack(alignment: .leading, spacing: 1) {
                    Text(fact.value)
                        .font(NookTheme.font(16, .semibold))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    Text(fact.label)
                        .font(NookTheme.font(11.5))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
