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

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack {
                Text(tr("actions.dispatch.title")).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.paper)
                Spacer(minLength: 0)
                ToolbarIconButton("xmark", tr("button.cancel")) { onClose() }
            }
            HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
                labeled(tr("actions.dispatch.workflow")) {
                    menu(workflow?.name ?? "", items: workflows.map { ($0.id, $0.name) }, selected: workflowID) { workflowID = $0 }
                }
                labeled(tr("actions.dispatch.branch")) {
                    menu(ref, items: (branches.isEmpty ? [info.defaultBranch] : branches).map { ($0, $0) }, selected: ref) { ref = $0 }
                }
            }
            if reading {
                ProgressView().controlSize(.small)
            } else if let inputs {
                ForEach(inputs) { input in field(input) }
            } else {
                Text(tr("actions.dispatch.notOnBranch", workflow?.name ?? "", ref))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error)
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coralSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: NookTheme.Spacing.sm) {
                if !missing.isEmpty, inputs != nil {
                    Text(tr("actions.dispatch.required"))
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textTertiary)
                }
                Spacer(minLength: 0)
                if sending { ProgressView().controlSize(.small) }
                SmallPrimaryButton(title: tr("actions.dispatch.run"), systemName: "play.fill") { run() }
                    .disabled(sending || reading || inputs == nil || !missing.isEmpty || workflow == nil)
            }
        }
        .padding(NookTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelCard()
        .task { branches = await store.dispatchBranches() }
        .task(id: "\(workflowID)|\(ref)") { await readInputs() }
        .onEscapeKey(perform: onClose)
    }

    // MARK: Parts

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
            Text(title).font(NookTheme.TextStyle.caption).foregroundStyle(NookTheme.textTertiary)
            content()
        }
    }

    private func menu<ID: Hashable>(_ title: String, items: [(ID, String)], selected: ID,
                                    pick: @escaping (ID) -> Void) -> some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    pick(item.0)
                } label: {
                    if item.0 == selected { Label(item.1, icon: "checkmark") } else { Text(item.1) }
                }
            }
        } label: {
            HStack(spacing: NookTheme.Spacing.xs) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Image(icon: "chevron.down").font(NookTheme.font(9, .semibold))
            }
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
        }
        .menuStyle(.nookBorderlessButton)
        .fixedSize()
    }

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
                menu(value.wrappedValue, items: input.options.map { ($0, $0) }, selected: value.wrappedValue) { value.wrappedValue = $0 }
                if !input.description.isEmpty { description(input.description) }
            }
        case .string, .number, .environment:
            labeled(title) {
                TextField(input.defaultValue, text: value)
                    .textFieldStyle(.plain)
                    .font(input.kind == .number ? NookTheme.mono(12) : NookTheme.TextStyle.body)
                    .padding(NookTheme.Spacing.sm)
                    .roundedBackground(NookTheme.smoke, radius: NookTheme.Radius.chip)
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
