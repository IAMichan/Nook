import SwiftUI

/// Wat Nook wil doen, stap voor stap, met alle details: waarheen, met welke inhoud, wat er verandert. Je kunt stappen
/// uitzetten, tekst aanpassen, en pas na Uitvoeren gebeurt er iets. Lukt een stap niet, dan zie je precies welke wel
/// en niet, en ga je veilig verder: wat al gelukt is, gebeurt niet nog een keer.
struct PlanReview: View {
    let message: ChatMessage
    @EnvironmentObject private var app: AppModel
    @State private var expanded: Set<Int> = []
    @State private var editing: Set<Int> = []

    private var steps: [PlanStep] { app.planSteps(message.actions) }

    private func state(_ index: Int) -> ActionStepState { message.actionStates[safe: index] ?? .pending }
    private func included(_ index: Int) -> Bool { message.actionIncluded[safe: index] ?? true }
    private func problems(_ index: Int) -> [String] { message.actionProblems[safe: index] ?? [] }

    /// Er valt nog iets te doen: wachtend, of na een fout.
    private var open: Bool {
        switch message.planState {
        case .pending, .failed: return true
        default: return false
        }
    }

    private var runnable: [Int] {
        message.actions.indices.filter { included($0) && state($0).canRun }
    }

    private var blocked: Bool {
        runnable.isEmpty || runnable.contains { !problems($0).isEmpty }
    }

    private var duplicates: Set<Int> {
        Set(message.actions.indices.filter { if case .duplicate = state($0) { return true }; return false })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.actions.count == 1 ? tr("chat.plan.reviewOne") : tr("chat.plan.review", message.actions.count))
                .font(NookTheme.font(10.5, .semibold))
                .foregroundStyle(NookTheme.textTertiary)

            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                stepView(index, step)
            }

            controls.padding(.top, 2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(NookTheme.field))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NookTheme.line2, lineWidth: 1))
    }

    // MARK: Eén stap

    @ViewBuilder
    private func stepView(_ index: Int, _ step: PlanStep) -> some View {
        let isOpen = expanded.contains(index) || !problems(index).isEmpty
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                marker(index, step)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.text)
                        .font(NookTheme.font(13.5))
                        .foregroundStyle(included(index) ? NookTheme.paper : NookTheme.textTertiary)
                        .strikethrough(!included(index))
                        .fixedSize(horizontal: false, vertical: true)
                    stateLine(index)
                }
                Spacer(minLength: 4)
                if !step.tag.isEmpty {
                    Text(step.tag)
                        .font(NookTheme.font(11.5, .medium))
                        .foregroundStyle(color(step.tone))
                }
                Button {
                    if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
                } label: {
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tr("chat.plan.details"))
            }

            if isOpen {
                details(index)
                    .padding(.leading, 27)
            }
        }
    }

    /// Vinkje om de stap aan of uit te zetten zolang er nog niets gebeurde; daarna de uitkomst.
    @ViewBuilder
    private func marker(_ index: Int, _ step: PlanStep) -> some View {
        switch state(index) {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(NookTheme.mint).frame(width: 18)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(NookTheme.coral).frame(width: 18)
        case .running:
            ProgressView().controlSize(.mini).frame(width: 18)
        case .duplicate:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(NookTheme.amber).frame(width: 18)
        default:
            if open {
                Button { app.setActionIncluded(message.id, index: index, !included(index)) } label: {
                    Image(systemName: included(index) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(included(index) ? color(step.tone) : NookTheme.textTertiary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(included(index) ? tr("chat.plan.exclude") : tr("chat.plan.include"))
            } else {
                Text("\(step.number)")
                    .font(NookTheme.font(10.5, .bold))
                    .foregroundStyle(color(step.tone))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(color(step.tone), lineWidth: 1.5))
            }
        }
    }

    @ViewBuilder
    private func stateLine(_ index: Int) -> some View {
        switch state(index) {
        case .done(let result):
            Text(result).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.mint).fixedSize(horizontal: false, vertical: true)
        case .failed(let error):
            Text(error).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.coralSoft).fixedSize(horizontal: false, vertical: true)
        case .duplicate(let when):
            Text(tr("chat.plan.duplicate", when)).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.amber)
        case .notRun:
            Text(tr("chat.plan.notRun")).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
        case .skipped:
            Text(tr("chat.plan.skipped")).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.textTertiary)
        case .running, .pending:
            EmptyView()
        }
    }

    /// Alle velden van de stap, volledig. Tekstvelden zijn aan te passen zolang de stap nog niet gelukt is.
    @ViewBuilder
    private func details(_ index: Int) -> some View {
        let action = message.actions[index]
        let fields = app.actionFields(action)
        let canEdit = open && state(index).canRun
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 2) {
                    Text(field.label)
                        .font(NookTheme.font(10.5, .semibold))
                        .foregroundStyle(NookTheme.textTertiary)
                    if editing.contains(index) && field.editable && canEdit {
                        TextField("", text: Binding(
                            get: { app.chat.message(message.id)?.actions[safe: index].flatMap { $0.input[field.key] as? String } ?? field.value },
                            set: { app.editAction(message.id, index: index, key: field.key, value: $0) }
                        ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(field.multiline ? 2...12 : 1...3)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(NookTheme.graphite))
                    } else {
                        Text(field.value)
                            .font(NookTheme.font(12.5))
                            .foregroundStyle(NookTheme.paper)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            ForEach(problems(index), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(NookTheme.font(11.5))
                    .foregroundStyle(NookTheme.coralSoft)
            }
            if canEdit && fields.contains(where: \.editable) {
                SmallGhostButton(title: editing.contains(index) ? tr("chat.plan.doneEditing") : tr("chat.plan.edit")) {
                    if editing.contains(index) { editing.remove(index) } else { editing.insert(index) }
                }
            }
        }
    }

    // MARK: Knoppen

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 6) {
            switch message.planState {
            case .pending:
                SmallPrimaryButton(title: tr("button.execute"), systemName: "checkmark") { app.runPlan(message.id) }
                    .disabled(blocked)
                    .opacity(blocked ? 0.45 : 1)
                SmallGhostButton(title: tr("button.cancel")) { app.cancelPlan(message.id) }
            case .running:
                ProgressView().controlSize(.small)
                Text(tr("chat.plan.running")).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textSecondary)
            case .done(let result):
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(NookTheme.mint)
                Text(result).font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.mint)
                    .fixedSize(horizontal: false, vertical: true)
            case .cancelled:
                Text(tr("chat.plan.cancelled")).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary)
            case .failed(let error):
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).font(NookTheme.font(12.5)).foregroundStyle(NookTheme.coralSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if !runnable.isEmpty {
                            SmallPrimaryButton(title: tr("chat.plan.continue"), systemName: "arrow.clockwise") { app.runPlan(message.id) }
                                .disabled(blocked)
                                .opacity(blocked ? 0.45 : 1)
                        }
                        if !duplicates.isEmpty {
                            SmallGhostButton(title: tr("chat.plan.runAnyway")) { app.runPlan(message.id, force: duplicates) }
                        }
                        SmallGhostButton(title: tr("chat.plan.stop")) { app.cancelPlan(message.id) }
                    }
                }
            }
            Spacer()
        }
    }

    private func color(_ tone: StepTone) -> Color {
        switch tone {
        case .good: return NookTheme.mint
        case .neutral: return NookTheme.textSecondary
        case .caution: return NookTheme.amber
        }
    }
}
