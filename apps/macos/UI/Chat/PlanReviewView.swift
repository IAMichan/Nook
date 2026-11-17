import SwiftUI

/// What Nook plans to do, step by step, with full details: target, content, and expected changes. Steps can be
/// toggled off and text adjusted before execution. If a step fails, you see exactly what succeeded and what failed,
/// allowing you to resume safely without repeating completed actions.
struct PlanReview: View {
    let message: ChatMessage
    // perf: read from the shared model, not observed: an answer's sources and plan must not redraw on every change of the app.
    private var app: AppModel { AppModel.shared }
    @State private var expanded: Set<Int> = []
    @State private var editing: Set<Int> = []
    /// A settled plan shows only its summary line until it is opened.
    @State private var showsSettledSteps = false
    @State private var hoveredStep: Int?

    private var steps: [PlanStep] { app.planSteps(message.actions) }

    private func state(_ index: Int) -> ActionStepState { message.actionStates[safe: index] ?? .pending }
    private func included(_ index: Int) -> Bool { message.actionIncluded[safe: index] ?? true }
    private func problems(_ index: Int) -> [String] { message.actionProblems[safe: index] ?? [] }

    /// Action remains to be taken: pending or following an error.
    private var open: Bool {
        if message.planArchived { return false }
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

    /// Steps that went through. The per-step lines already say what happened, so a finished plan needs no repeat below.
    private var succeeded: Int {
        message.actions.indices.count(where: { state($0).result != nil })
    }

    private var finished: Bool {
        if case .done = message.planState { return succeeded > 0 }
        return false
    }

    private var header: String {
        let count = message.actions.count
        if message.planArchived { return count == 1 ? tr("chat.plan.archivedOne") : tr("chat.plan.archived", count) }
        return count == 1 ? tr("chat.plan.reviewOne") : tr("chat.plan.review", count)
    }

    /// Steps left out of the run: unchecked by the user, or never reached.
    private var leftOutCount: Int {
        message.actions.indices.count(where: { leftOut($0) })
    }

    /// The one line a settled plan folds to: how many steps went through, and how many were left out.
    private var settledSummary: String {
        let count = message.actions.count
        return succeeded < count ? tr("chat.plan.settledSome", succeeded, count) : tr("chat.plan.settledAll", count)
    }

    /// Where a failed plan stands, when a step shows the reason itself; nil falls back to the plan's own error.
    private var failureHeadline: String? {
        let stopped = message.actions.indices.contains { index in
            switch state(index) {
            case .failed, .duplicate: return true
            default: return false
            }
        }
        guard stopped else { return nil }
        return succeeded == 0 ? tr("chat.plan.failedNone") : tr("chat.plan.failedSome", succeeded, message.actions.count)
    }

    /// Everything left to run failed before: the button tries again rather than continuing.
    private var onlyRetries: Bool {
        runnable.allSatisfy { if case .failed = state($0) { return true }; return false }
    }

    private var duplicates: Set<Int> {
        Set(message.actions.indices.filter { if case .duplicate = state($0) { return true }; return false })
    }

    var body: some View {
        // Under review: a title, the steps split by a hairline, and the buttons. Once it went through, the plan needs no
        // more attention and folds to one line that opens the steps again.
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if finished {
                settledLine
            } else {
                Text(header)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
            }

            if !finished || showsSettledSteps {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 { NookDivider(inset: Self.textInset) }
                        stepView(index, step)
                            .padding(.vertical, NookTheme.Spacing.md)
                    }
                }
                .transition(.opacity)
            }

            if !finished {
                controls
            }
        }
        .padding(.horizontal, NookTheme.Spacing.xl)
        .padding(.vertical, finished && !showsSettledSteps ? NookTheme.Spacing.lg : NookTheme.Spacing.xl)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.sheet)
    }

    // MARK: Settled plan

    /// A finished plan as one line: a check, what went through (the step itself when there is one), the apps it touched,
    /// and a chevron. Clicking it shows or hides the steps.
    private var settledLine: some View {
        Button {
            withNookAnimation(NookTheme.Motion.list) { showsSettledSteps.toggle() }
        } label: {
            HStack(alignment: .center, spacing: Self.markerGap) {
                Image(icon: "checkmark.circle.fill")
                    .foregroundStyle(NookTheme.mint)
                    .frame(width: Self.markerWidth)
                if steps.count == 1, let step = steps.first {
                    let parts = Self.parts(of: step)
                    if step.source != nil { StepSourceIcon(source: step.source) }
                    Text(Self.leadAndBody(parts))
                        .font(NookTheme.TextStyle.body)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(settledSummary)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(1)
                    if leftOutCount > 0 {
                        Text(tr("chat.plan.settledSkipped", leftOutCount))
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.textTertiary)
                            .lineLimit(1)
                    }
                    sourceStack
                }
                Spacer(minLength: NookTheme.Spacing.sm)
                DisclosureChevron(open: showsSettledSteps, style: .vertical)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .nookTip(showsSettledSteps ? tr("chat.plan.hideSteps") : tr("chat.plan.showSteps"))
        .accessibilityLabel(settledSummary)
    }

    /// The apps a plan touched, each once, slightly overlapping like the sources above an answer.
    private var sourceStack: some View {
        var seen = Set<String>()
        let sources = steps.compactMap(\.source).filter { seen.insert($0).inserted }
        return HStack(spacing: -4) {
            ForEach(sources.prefix(4), id: \.self) { source in
                StepSourceIcon(source: source, size: 12)
                    .padding(1.5)
                    .background(Circle().fill(NookTheme.graphite))
                    .overlay(Circle().stroke(NookTheme.field, lineWidth: 1))
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Single step

    /// Where a step's text starts: the marker's width plus the gap after it. Dividers and details line up with it.
    private static let markerWidth: CGFloat = 18
    private static let markerGap: CGFloat = 9
    private static let textInset: CGFloat = markerWidth + markerGap

    /// A step's summary as where it goes ("WhatsApp → Anna", "Reminder") and what it does, or only the latter.
    static func parts(of step: PlanStep) -> (lead: String?, body: String) {
        let split = ActionGate.splitSummary(step.text)
        return (split.lead ?? step.source.map(SourceCatalog.title), split.body)
    }

    /// "WhatsApp → Anna · see you at 8" on one line: the target quiet, what it does bright.
    private static func leadAndBody(_ parts: (lead: String?, body: String)) -> AttributedString {
        var body = AttributedString(parts.body)
        body.foregroundColor = NookTheme.paper
        guard let lead = parts.lead else { return body }
        var front = AttributedString("\(lead) · ")
        front.foregroundColor = NookTheme.textSecondary
        return front + body
    }

    /// A step left out of the run (unchecked, or never reached): it reads as quiet history, not as work still to do.
    private func leftOut(_ index: Int) -> Bool {
        switch state(index) {
        case .skipped, .notRun: return true
        case .pending: return !included(index)
        default: return false
        }
    }

    @ViewBuilder
    private func stepView(_ index: Int, _ step: PlanStep) -> some View {
        let isOpen = expanded.contains(index) || !problems(index).isEmpty
        let parts = Self.parts(of: step)
        // The tag warns before the run ("sends", "removes"); once the step is settled it has nothing to warn about.
        let warns = !step.tag.isEmpty && state(index).canRun && open
        let quiet = leftOut(index)
        // Once the plan is settled, a long step (a whole message) folds to two lines; the details hold the full text.
        let folded = !open && !isOpen
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Self.markerGap) {
                marker(index, step)
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                    // Where it goes, small, with the app's icon: the eye finds the target before reading the content.
                    if parts.lead != nil || warns {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            if let lead = parts.lead {
                                if step.source != nil {
                                    StepSourceIcon(source: step.source)
                                        .opacity(quiet ? 0.5 : 1)
                                }
                                Text(lead)
                                    .font(NookTheme.TextStyle.label)
                                    .foregroundStyle(quiet ? NookTheme.textTertiary : NookTheme.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            if warns {
                                NookTag(step.tag, tint: color(step.tone))
                            }
                        }
                    }
                    Text(parts.body)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(quiet ? NookTheme.textTertiary : NookTheme.paper)
                        // Strike through only while the user can still tick it back on; afterwards the marker says it.
                        .strikethrough(open && !included(index))
                        .lineLimit(folded ? 2 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                    stateLine(index)
                }
                Spacer(minLength: NookTheme.Spacing.xs)
                ToolbarIconButton(isOpen ? "chevron.up" : "chevron.down", tr("chat.plan.details"), height: 20, width: 20) {
                    toggleDetails(index)
                }
                // Details are there when wanted, out of sight at rest.
                .revealOnHover(isOpen || hoveredStep == index, animated: true)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredStep = index } else if hoveredStep == index { hoveredStep = nil }
            }

            if isOpen {
                details(index)
                    .padding(.leading, Self.textInset)
                    .transition(.opacity)
            }
        }
    }

    private func toggleDetails(_ index: Int) {
        withNookAnimation(NookTheme.Motion.list) {
            if expanded.contains(index) { expanded.remove(index) } else { expanded.insert(index) }
        }
    }

    /// Checkbox to toggle the step before execution; shows the outcome afterwards.
    @ViewBuilder
    private func marker(_ index: Int, _ step: PlanStep) -> some View {
        switch state(index) {
        case .done:
            Image(icon: "checkmark.circle.fill").foregroundStyle(NookTheme.mint).frame(width: Self.markerWidth)
        case .verified:
            Image(icon: "checkmark.seal.fill").foregroundStyle(NookTheme.mint).frame(width: Self.markerWidth)
                .nookTip(tr("chat.plan.verified"))
        case .approved:
            Image(icon: "clock").foregroundStyle(NookTheme.textSecondary).frame(width: Self.markerWidth)
        case .failed:
            Image(icon: "xmark.circle.fill").foregroundStyle(NookTheme.coral).frame(width: Self.markerWidth)
        case .running:
            ProgressView().controlSize(.mini).frame(width: Self.markerWidth)
        case .duplicate:
            Image(icon: "exclamationmark.circle.fill").foregroundStyle(NookTheme.amber).frame(width: Self.markerWidth)
        case .skipped, .notRun:
            Image(icon: "minus.circle").foregroundStyle(NookTheme.textTertiary).frame(width: Self.markerWidth)
        default:
            if open {
                Button { app.setActionIncluded(message.id, index: index, !included(index)) } label: {
                    Image(icon: included(index) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(included(index) ? color(step.tone) : NookTheme.textTertiary)
                        .frame(width: Self.markerWidth)
                }
                .buttonStyle(.nookPlain)
                .nookTip(included(index) ? tr("chat.plan.exclude") : tr("chat.plan.include"))
            } else {
                Text("\(step.number)")
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textSecondary)
                    .frame(width: Self.markerWidth, height: Self.markerWidth)
                    .overlay(Circle().stroke(NookTheme.textTertiary, lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private func stateLine(_ index: Int) -> some View {
        switch state(index) {
        case .done:
            // The green check already says it went through; a second "Done" under every step is noise.
            EmptyView()
        case .verified:
            Text(tr("chat.plan.stepVerified")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.mint)
        case .approved:
            Text(tr("chat.plan.approved")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
        case .failed(let error):
            StepFailure(error: error).padding(.top, 4)
        case .duplicate(let when):
            Text(tr("chat.plan.duplicate", when)).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
        case .notRun:
            Text(tr("chat.plan.notRun")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
        case .skipped:
            Text(tr("chat.plan.skipped")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
        case .running, .pending:
            EmptyView()
        }
    }

    /// All step fields in full. Text fields are editable until the step has succeeded.
    @ViewBuilder
    private func details(_ index: Int) -> some View {
        let action = message.actions[index]
        let fields = app.actionFields(action)
        let canEdit = open && state(index).canRun
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(field.label)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                    if editing.contains(index) && field.editable && canEdit {
                        TextField("", text: Binding(
                            get: { app.chat.message(message.id)?.actions[safe: index].flatMap { $0.input[field.key] as? String } ?? field.value },
                            set: { app.editAction(message.id, index: index, key: field.key, value: $0) }
                        ), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(NookTheme.TextStyle.body)
                        .foregroundStyle(NookTheme.paper)
                        .lineLimit(field.multiline ? 2...12 : 1...3)
                        .padding(NookTheme.Spacing.md)
                        .roundedBackground(NookTheme.graphite, radius: NookTheme.Radius.control)
                    } else {
                        Text(field.value)
                            .font(NookTheme.TextStyle.body)
                            .foregroundStyle(NookTheme.paper)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            // The raw tool output (ids and all) stays available here, out of the way.
            if let result = state(index).result {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("chat.plan.result"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(result)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(problems(index), id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
            }
            if canEdit && fields.contains(where: \.editable) {
                SmallGhostButton(title: editing.contains(index) ? tr("chat.plan.doneEditing") : tr("chat.plan.edit")) {
                    if editing.contains(index) { editing.remove(index) } else { editing.insert(index) }
                }
            }
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            switch message.planState {
            case .pending where message.planArchived:
                // A plan from an earlier session: it shows what was proposed, but runs only from a new request.
                Text(tr("chat.plan.notExecuted")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textTertiary)
            case .pending:
                // Says how much will happen, so the click is never a surprise.
                SmallPrimaryButton(title: runnable.count > 1 ? tr("chat.plan.runMany", runnable.count) : tr("button.execute"),
                                   systemName: "checkmark") { app.runPlan(message.id) }
                    .disabled(blocked)
                SmallGhostButton(title: tr("button.cancel")) { app.cancelPlan(message.id) }
            case .running:
                BusyLine(tr("chat.plan.running"), font: NookTheme.TextStyle.body)
            case .done(let result):
                Image(icon: "checkmark").font(NookTheme.font(11, .bold)).foregroundStyle(NookTheme.mint)
                Text(result).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.mint)
                    .fixedSize(horizontal: false, vertical: true)
            case .cancelled:
                Text(tr("chat.plan.cancelled")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textTertiary)
            case .failed(let error):
                VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                    // The step itself already shows why; here only where the plan stands, so the reason is not repeated.
                    Text(failureHeadline ?? error)
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !message.planArchived {
                        HStack(spacing: 6) {
                            if !runnable.isEmpty {
                                SmallPrimaryButton(title: onlyRetries ? tr("chat.retry") : tr("chat.plan.continue"),
                                                   systemName: "arrow.clockwise") { app.runPlan(message.id) }
                                    .disabled(blocked)
                            }
                            if !duplicates.isEmpty {
                                SmallGhostButton(title: tr("chat.plan.runAnyway")) { app.runPlan(message.id, force: duplicates) }
                            }
                            SmallGhostButton(title: tr("chat.plan.stop")) { app.cancelPlan(message.id) }
                        }
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

/// The app a plan step acts on (WhatsApp, Calendar, GitHub…), drawn as the sources above an answer draw it.
struct StepSourceIcon: View {
    let source: String?
    var size: CGFloat = 13

    var body: some View {
        let connector = source.flatMap { AppModel.shared.connectors.source(id: $0) }
        SiteIcon(domain: connector?.iconDomain, fallback: connector?.symbol ?? SourcesDisclosure.symbol(source),
                 tint: NookTheme.textSecondary, size: size, source: source)
    }
}

/// Why a step did not go through, as a quiet coral block instead of a wall of red text. A multi-line report (a batch
/// merge, for one) gets a line per item, each with its own symbol: ✓ went through, – skipped, ✗ refused.
private struct StepFailure: View {
    let error: String

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let symbol: String?
        let color: Color
    }

    /// The first line plain is the headline; the rest carry their symbol, or none for a plain follow-up line.
    private var lines: [Line] {
        error.split(separator: "\n", omittingEmptySubsequences: true).enumerated().map { index, raw in
            let text = raw.trimmingCharacters(in: .whitespaces)
            for (prefix, symbol, color) in [("✓ ", "checkmark.circle.fill", NookTheme.mint),
                                            ("– ", "minus.circle.fill", NookTheme.amber),
                                            ("✗ ", "xmark.circle.fill", NookTheme.coral)] where text.hasPrefix(prefix) {
                return Line(id: index, text: String(text.dropFirst(prefix.count)), symbol: symbol, color: color)
            }
            if index == 0 { return Line(id: index, text: text, symbol: "exclamationmark.triangle.fill", color: NookTheme.coral) }
            return Line(id: index, text: text, symbol: nil, color: NookTheme.textSecondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                    Image(icon: line.symbol ?? "circle")
                        .font(NookTheme.font(10.5, .semibold))
                        .foregroundStyle(line.color)
                        .frame(width: 14)
                        .opacity(line.symbol == nil ? 0 : 1)
                    Text(line.text)
                        .font(line.id == 0 ? NookTheme.TextStyle.label : NookTheme.TextStyle.detail)
                        .foregroundStyle(line.id == 0 ? NookTheme.coralSoft : NookTheme.textStrong)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .padding(.vertical, NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(NookTheme.coral.opacity(0.08), radius: NookTheme.Radius.control)
    }
}
