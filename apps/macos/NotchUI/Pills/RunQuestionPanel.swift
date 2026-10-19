import SwiftUI

/// A question from the agent in place of the composer, one at a time: its options as buttons (keys 1–9
/// pick one), several for a multiple choice, or an answer of your own. A single choice moves on by itself.
struct RunQuestionPanel: View {
    let question: PendingQuestion
    let agent: String
    /// Stops the agent instead of answering (the composer with its Stop button is hidden meanwhile).
    var onStop: (() -> Void)? = nil
    let onAnswer: ([String: [String]]) -> Void
    @State private var index = 0
    @State private var answers: [String: [String]] = [:]
    @State private var picks: Set<String> = []
    @State private var own = ""
    @FocusState private var ownFocused: Bool

    private var item: RunQuestion? { question.questions.indices.contains(index) ? question.questions[index] : nil }
    private var isLast: Bool { index >= question.questions.count - 1 }

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "questionmark.bubble.fill").foregroundStyle(NookTheme.amber)
                    Text(item.header.isEmpty ? tr("ws.question.title", agent) : item.header)
                        .font(NookTheme.font(12, .semibold))
                        .foregroundStyle(NookTheme.textSecondary)
                    Spacer(minLength: 6)
                    if question.questions.count > 1 {
                        Text("\(index + 1)/\(question.questions.count)")
                            .font(NookTheme.font(11.5))
                            .foregroundStyle(NookTheme.textTertiary)
                            .monospacedDigit()
                    }
                    if let onStop {
                        Button(action: onStop) {
                            Label(tr("ws.question.stop"), systemImage: "stop.fill").labelStyle(.iconOnly)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(NookTheme.textSecondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(NookTheme.smoke))
                        }
                        .buttonStyle(.plain)
                        .help(tr("ws.question.stop"))
                        .accessibilityLabel(tr("ws.question.stop"))
                    }
                }
                Text(item.question)
                    .font(NookTheme.font(13.5, .medium))
                    .foregroundStyle(NookTheme.paper)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                        optionButton(item, option, number: number)
                    }
                }
                if item.allowsOther {
                    HStack(spacing: 8) {
                        TextField(tr("ws.question.own"), text: $own)
                            .textFieldStyle(.plain)
                            .font(NookTheme.font(13))
                            .focused($ownFocused)
                            .onSubmit { submitOwn(item) }
                        if !own.trimmingCharacters(in: .whitespaces).isEmpty {
                            NookGhostButton(title: isLast ? tr("ws.question.send") : tr("ws.question.next")) { submitOwn(item) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(NookTheme.field))
                }
                if item.multiSelect, !picks.isEmpty {
                    HStack {
                        Spacer()
                        NookPrimaryButton(title: isLast ? tr("ws.question.send") : tr("ws.question.next")) {
                            record(item, Array(picks))
                        }
                    }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NookTheme.amber.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(NookTheme.amber.opacity(0.25), lineWidth: 1))
            // Keys 1–9 pick an option, except while you type your own answer.
            .background { if !ownFocused { digitShortcuts(item) } }
        }
    }

    private func optionButton(_ item: RunQuestion, _ option: RunQuestionOption, number: Int) -> some View {
        let picked = picks.contains(option.label)
        return Button {
            if item.multiSelect {
                if picked { picks.remove(option.label) } else { picks.insert(option.label) }
            } else {
                record(item, [option.label])
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number < 9 ? "\(number + 1)" : "·")
                    .font(NookTheme.mono(11, .medium))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(NookTheme.font(13, .medium)).foregroundStyle(NookTheme.paper)
                    if !option.description.isEmpty {
                        Text(option.description).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if item.multiSelect {
                    Image(systemName: picked ? "checkmark.square.fill" : "square").foregroundStyle(picked ? NookTheme.paper : NookTheme.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(picked ? NookTheme.smoke : NookTheme.field))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Keys 1–9 choose an option. Hidden buttons carry the shortcuts.
    private func digitShortcuts(_ item: RunQuestion) -> some View {
        ZStack {
            ForEach(Array(item.options.prefix(9).enumerated()), id: \.offset) { number, option in
                Button("") {
                    if item.multiSelect {
                        if picks.contains(option.label) { picks.remove(option.label) } else { picks.insert(option.label) }
                    } else {
                        record(item, [option.label])
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number + 1)")), modifiers: [])
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func submitOwn(_ item: RunQuestion) {
        let text = own.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        record(item, Array(picks) + [text])
    }

    private func record(_ item: RunQuestion, _ values: [String]) {
        answers[item.id] = values
        picks = []
        own = ""
        if isLast {
            onAnswer(answers)
        } else {
            withAnimation(.easeInOut(duration: 0.15)) { index += 1 }
        }
    }
}
