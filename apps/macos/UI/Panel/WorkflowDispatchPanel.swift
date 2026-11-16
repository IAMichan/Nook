import SwiftUI

/// Starts a workflow by hand from the Actions page, as "Run workflow" does on GitHub: which workflow (those with a
/// `workflow_dispatch` trigger), on which branch, and the inputs its file asks for (a field, a checkbox, or a choice),
/// required ones marked. The inputs are read from the workflow's file on the branch you pick, since another branch may
/// ask for others. One click on Run sends it; the new run opens when GitHub names it.
struct WorkflowDispatchPanel: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var store: ActionsStore
    let info: ActionsDispatchInfo
    let onClose: () -> Void
    let onStarted: (WorkflowRun?) -> Void

    @State private var workflowID: Int
    @State private var ref: String
    @State private var branches: [String] = []
    /// The inputs of the workflow on `ref`; nil when it cannot be started there.
    @State private var inputs: [WorkflowInput]?
    @State private var reading = false
    @State private var values: [String: String] = [:]
    @State private var sending = false
    @State private var error: String?

    init(store: ActionsStore, info: ActionsDispatchInfo, workflowID: Int, onClose: @escaping () -> Void,
         onStarted: @escaping (WorkflowRun?) -> Void) {
        self.store = store
        self.info = info
        self.onClose = onClose
        self.onStarted = onStarted
        _workflowID = State(initialValue: workflowID)
        _ref = State(initialValue: info.defaultBranch)
        _inputs = State(initialValue: info.inputs[workflowID])
        _values = State(initialValue: Self.initialValues(info.inputs[workflowID] ?? [], keeping: [:]))
    }

    /// The workflows that can be started by hand, in the page's order.
    private var workflows: [Workflow] { store.workflows.filter { info.inputs[$0.id] != nil } }
    private var workflow: Workflow? { store.workflows.first { $0.id == workflowID } }
    private var missing: [String] { WorkflowDispatch.missing(inputs ?? [], values: values) }

    /// The form keeps to one readable column, also on a wide window, so the Run button stays near the fields.
    private static let columnWidth: CGFloat = 560
    private static let fieldWidth: CGFloat = 320
    private static let branchWidth: CGFloat = 220

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
            header
            HStack(alignment: .top, spacing: NookTheme.Spacing.md) {
                labeled(tr("actions.dispatch.workflow")) { workflowPicker }
                labeled(tr("actions.dispatch.branch")) { branchPicker }
            }
            inputsSection
            if let error { InlineErrorText(error) }
            NookDivider()
            footer
        }
        .frame(maxWidth: Self.columnWidth, alignment: .leading)
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .task { branches = await store.dispatchBranches() }
        .task(id: "\(workflowID)|\(ref)") { await readInputs() }
        .onEscapeKey(perform: onClose)
    }

    // MARK: Parts

    /// The title, what the form does and in which repository, and the close button.
    private var header: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.sm) {
            Image(icon: "play.circle")
                .font(NookTheme.font(16, .medium))
                .foregroundStyle(NookTheme.textSecondary)
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("actions.dispatch.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Text(tr("actions.dispatch.subtitle", store.repo ?? ""))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ToolbarIconButton("xmark", tr("button.cancel")) { onClose() }
        }
    }

    /// The workflows that can be started by hand, each with its file, a search once the list is long.
    private var workflowPicker: some View {
        ComposerDropdown(width: Self.fieldWidth, scrolls: workflows.count > 8) {
            fieldFace(symbol: "bolt", title: workflow?.name ?? "", detail: workflow.map { fileName($0.path) },
                      width: Self.fieldWidth)
        } content: {
            ForEach(workflows) { item in
                DropdownRow(title: item.name, detail: item.path, chosen: item.id == workflowID) { workflowID = item.id }
            }
        }
    }

    /// The branches with a search over them, as the new session composer picks a branch.
    private var branchPicker: some View {
        ComposerDropdown(width: Self.branchWidth + 40) {
            fieldFace(symbol: "arrow.triangle.branch", title: ref, detail: nil, width: Self.branchWidth)
        } content: {
            BranchPicker(branches: branches.isEmpty ? [info.defaultBranch] : branches, selected: ref) { ref = $0 }
        }
    }

    /// What the workflow asks for on the chosen branch: its inputs, a line that it asks for nothing, or why it cannot
    /// be started there.
    @ViewBuilder
    private var inputsSection: some View {
        if reading {
            BusyLine(tr("actions.dispatch.reading", ref), tone: .tertiary, font: NookTheme.TextStyle.detail)
        } else if let inputs, !inputs.isEmpty {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Text(tr("actions.dispatch.inputs")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textSecondary)
                    if inputs.contains(where: { $0.required && $0.kind != .boolean }) {
                        Text(tr("actions.dispatch.required"))
                            .font(NookTheme.TextStyle.caption)
                            .foregroundStyle(NookTheme.textTertiary)
                    }
                }
                ForEach(inputs) { input in field(input) }
            }
        } else if inputs != nil {
            note(symbol: "checkmark.circle", tr("actions.dispatch.noInputs"))
        } else {
            note(symbol: "exclamationmark.triangle", tr("actions.dispatch.notOnBranch", workflow?.name ?? "", ref))
        }
    }

    /// What one click on Run does, Cancel, and Run.
    private var footer: some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            Text(summary)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .lineLimit(2)
            Spacer(minLength: NookTheme.Spacing.md)
            if sending { ProgressView().controlSize(.small) }
            SmallGhostButton(title: tr("button.cancel")) { onClose() }
            SmallPrimaryButton(title: tr("actions.dispatch.run"), systemName: "play.fill") { run() }
                .disabled(sending || reading || inputs == nil || !missing.isEmpty || workflow == nil)
        }
    }

    /// "Runs CI on main", or what is still missing before it can.
    private var summary: String {
        if inputs != nil, !missing.isEmpty { return tr("actions.dispatch.missing", missing.joined(separator: ", ")) }
        return tr("actions.dispatch.summary", workflow?.name ?? "", ref)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(title).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            content()
        }
    }

    /// The face of a dropdown in the form: drawn as a field (fill, hairline, chevron), so it reads as a choice to make.
    private func fieldFace(symbol: String?, title: String, detail: String?, width: CGFloat) -> some View {
        HStack(spacing: NookTheme.Spacing.sm) {
            if let symbol {
                Image(icon: symbol).font(NookTheme.font(11, .medium)).foregroundStyle(NookTheme.textTertiary)
            }
            Text(title)
                .font(NookTheme.TextStyle.body)
                .foregroundStyle(NookTheme.paper)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail {
                Text(detail)
                    .font(NookTheme.TextStyle.caption)
                    .foregroundStyle(NookTheme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(icon: "chevron.down").font(NookTheme.font(9, .semibold)).foregroundStyle(NookTheme.textTertiary)
        }
        .padding(.horizontal, NookTheme.Spacing.sm)
        .frame(width: width, height: 30)
        .fieldBox()
        .contentShape(Rectangle())
    }

    private func note(symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.sm) {
            Image(icon: symbol).font(NookTheme.font(11, .medium)).foregroundStyle(NookTheme.textTertiary)
            Text(text)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fileName(_ path: String) -> String { (path as NSString).lastPathComponent }

    /// One input: its name (and a mark when it is required), what it is for, and its control.
    @ViewBuilder
    private func field(_ input: WorkflowInput) -> some View {
        let value = Binding(get: { values[input.name] ?? input.initialValue }, set: { values[input.name] = $0 })
        let title = input.name + (input.required && input.kind != .boolean ? " *" : "")
        switch input.kind {
        case .boolean:
            Toggle(isOn: Binding(get: { WorkflowDispatch.isTrue(value.wrappedValue) }, set: { value.wrappedValue = String($0) })) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                    Text(input.name).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.paper)
                    if !input.description.isEmpty { description(input.description) }
                }
            }
            .toggleStyle(.checkbox)
        case .choice:
            labeled(title) {
                ComposerDropdown(width: Self.fieldWidth, scrolls: input.options.count > 10) {
                    fieldFace(symbol: nil, title: value.wrappedValue, detail: nil, width: Self.fieldWidth)
                } content: {
                    ForEach(input.options, id: \.self) { option in
                        DropdownRow(title: option, chosen: option == value.wrappedValue) { value.wrappedValue = option }
                    }
                }
                if !input.description.isEmpty { description(input.description) }
            }
        case .string, .number, .environment:
            labeled(title) {
                TextField(input.defaultValue, text: value)
                    .textFieldStyle(.plain)
                    .font(input.kind == .number ? NookTheme.mono(12) : NookTheme.TextStyle.body)
                    .padding(.horizontal, NookTheme.Spacing.sm)
                    .frame(maxWidth: Self.columnWidth, minHeight: 30)
                    .fieldBox()
                    .onSubmit { run() }
                if !input.description.isEmpty { description(input.description) }
            }
        }
    }

    private func description(_ text: String) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(NookTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Work

    /// The inputs as the workflow's file reads on the chosen branch; what you typed stays for inputs with the same name.
    private func readInputs() async {
        guard let workflow else { return }
        if ref == info.defaultBranch {
            apply(info.inputs[workflow.id])
            return
        }
        reading = true
        let read = try? await store.dispatchInputs(workflow, ref: ref)
        guard !Task.isCancelled else { return }
        reading = false
        apply(read ?? nil)
    }

    private func apply(_ read: [WorkflowInput]?) {
        inputs = read
        values = Self.initialValues(read ?? [], keeping: values)
        error = nil
    }

    private static func initialValues(_ inputs: [WorkflowInput], keeping kept: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: inputs.map { ($0.name, kept[$0.name] ?? $0.initialValue) })
    }

    /// Only after your click on Run: starts the workflow, writes it to the action log, and opens the new run.
    private func run() {
        guard let workflow, let inputs, missing.isEmpty, !sending else { return }
        sending = true
        error = nil
        let args = "\(store.repo ?? "") workflow \(workflow.id) on \(ref)"
        Task {
            do {
                let run = try await store.dispatch(workflow: workflow, ref: ref, inputs: inputs, values: values)
                app.store.audit(tool: "github_dispatch_workflow", args: args, result: "ok")
                ToastCenter.shared.success(tr("actions.dispatch.started", workflow.name))
                sending = false
                onStarted(run)
            } catch {
                app.store.audit(tool: "github_dispatch_workflow", args: args, result: "error: " + error.localizedDescription)
                sending = false
                self.error = error.localizedDescription
            }
        }
    }
}

private extension View {
    /// The box of a field in the run form: a dropdown's face and a text field look the same.
    func fieldBox() -> some View {
        roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.control)
            .roundedStrokeBorder(NookTheme.fieldStroke, radius: NookTheme.Radius.control)
    }
}
