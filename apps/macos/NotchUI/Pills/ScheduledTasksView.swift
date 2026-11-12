import SwiftUI
import AppKit

/// The list of scheduled tasks: what runs, when it runs next, how the last run went, with an
/// enable switch and "run now" per task, and an editor sheet. Opened from Settings › Agents › Workspace; the whole feature
/// is behind `WorkspaceSettings.scheduledTasksEnabled`.
struct ScheduledTasksView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var settings = WorkspaceSettings.shared
    @ObservedObject private var listener = WebhookListener.shared
    let onClose: () -> Void

    @State private var editing: EditorTarget?
    @State private var deleting: ScheduledTask?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        var existing: ScheduledTask?
    }

    var body: some View {
        // The one sheet shape of Settings: what this is on top, the tasks in the middle, New task and Done below.
        SetupSheet(title: tr("sched.title"), subtitle: tr("sched.subtitle"), width: 620) {
            SettingsTile(.automation, size: 40)
        } content: {
            if !settings.scheduledTasksEnabled { banner(tr("sched.disabledGlobal"), color: NookTheme.amber) }
            if case .failed(let message) = listener.state { banner(tr("sched.webhook.failed", message), color: NookTheme.coralSoft) }
            if store.tasks.isEmpty {
                // No task yet: the sheet says so and offers the first one, as the empty Agents and Nook lists do.
                WSEmptyState(symbol: "calendar.badge.clock", title: tr("sched.empty"), message: tr("sched.empty.detail"),
                             action: (tr("sched.new"), { editing = EditorTarget(existing: nil) }))
            } else {
                LazyVStack(spacing: NookTheme.Spacing.md) {
                    ForEach(store.tasks) { task in
                        TaskRow(task: task,
                                running: store.isRunning(task.id),
                                canRun: settings.scheduledTasksEnabled,
                                toggle: { store.setEnabled(task.id, $0) },
                                runNow: { run(task) },
                                edit: { editing = EditorTarget(existing: task) },
                                delete: { deleting = task })
                            .contextMenu {
                                Button(tr("sched.runNow")) { run(task) }
                                    .disabled(!settings.scheduledTasksEnabled || store.isRunning(task.id))
                                Button(tr("sched.edit")) { editing = EditorTarget(existing: task) }
                                Divider()
                                Button(tr("sched.delete"), role: .destructive) { deleting = task }
                            }
                    }
                }
                // A task added or removed glides into place instead of the list jumping.
                .animation(NookTheme.reveal, value: store.tasks.map(\.id))
            }
        } footer: {
            if !store.tasks.isEmpty {
                Button(tr("sched.new")) { editing = EditorTarget(existing: nil) }
                    .controlSize(.large)
            }
            Spacer()
            Button(tr("settings2.done"), action: onClose)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.nookProminent)
                .controlSize(.large)
        }
        .sheet(item: $editing) { target in
            ScheduledTaskEditor(existing: target.existing) { editing = nil }
                .environmentObject(app)
        }
        .confirmDelete($deleting, question: { tr("sched.delete.confirm", $0.title) }, confirmTitle: tr("sched.delete")) { task in
            store.delete(task.id)
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(NookTheme.TextStyle.detail)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NookTheme.Spacing.lg)
            .padding(.vertical, NookTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
    }

    private func run(_ task: ScheduledTask) {
        switch store.runNow(task.id) {
        case .started: ToastCenter.shared.success(tr("sched.started", task.title))
        case .busy: ToastCenter.shared.warning(tr("sched.busy", task.title))
        case .notAvailable: ToastCenter.shared.warning(tr("sched.disabledGlobal"))
        }
    }
}

// MARK: Row

private struct TaskRow: View {
    let task: ScheduledTask
    let running: Bool
    let canRun: Bool
    let toggle: (Bool) -> Void
    let runNow: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                Text(task.title.isEmpty ? tr("sched.untitled") : task.title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(task.enabled ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                Text(ScheduledTaskText.summary(task.rule))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textSecondary)
                HStack(spacing: NookTheme.Spacing.md) {
                    statusChip
                    Text(timing)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                if let error = ScheduledTaskText.error(task), !running {
                    Text(error)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(task.lastStatus == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: NookTheme.Spacing.xxs) {
                NookIconButton(systemName: "play.fill", label: tr("sched.runNow"), size: 28, action: runNow)
                    .disabled(running || !canRun)
                    .help(tr("sched.runNow"))
                NookIconButton(systemName: "pencil", label: tr("sched.edit"), size: 28, action: edit)
                    .help(tr("sched.edit"))
                NookIconButton(systemName: "trash", label: tr("sched.delete"), size: 28, action: delete)
                    .help(tr("sched.delete"))
                Toggle(tr("sched.enabled"), isOn: Binding(get: { task.enabled }, set: toggle))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .padding(.leading, NookTheme.Spacing.sm)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .panelCard()
    }

    private var effectiveStatus: ScheduledRunStatus? { running ? .running : task.lastStatus }

    @ViewBuilder
    private var statusChip: some View {
        if let status = effectiveStatus {
            let color = ScheduledTaskText.color(status)
            StatusBadgeLabel(word: tr("sched.status." + status.rawValue), tint: color) {
                Circle().fill(color).frame(width: 6, height: 6)
            }
        } else {
            Text(tr("sched.never"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private var timing: String {
        var parts: [String] = []
        if let last = task.lastRun { parts.append(tr("sched.last", ScheduledTaskText.date(last))) }
        if task.enabled, let next = task.nextRun, !running { parts.append(tr("sched.next", ScheduledTaskText.date(next))) }
        if task.enabled, task.rule.isWebhook { parts.append(tr("sched.waitingWebhook")) }
        if task.isDone { parts.append(tr("automation.sched.done")) }
        if task.target.sessionID != nil {
            parts.append(tr(task.target.freshConversation ? "automation.sched.fresh" : "automation.sched.continue"))
        }
        return parts.joined(separator: " · ")
    }
}

/// Texts for rules, dates and outcomes, shared by the list and the editor.
enum ScheduledTaskText {
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func time(hour: Int, minute: Int) -> String {
        let calendar = Calendar.current
        let day = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
        return day.formatted(date: .omitted, time: .shortened)
    }

    /// Weekdays in the order the user's calendar starts the week (1 = Sunday).
    static func orderedWeekdays(_ calendar: Calendar = .current) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    static func weekdayName(_ day: Int, _ calendar: Calendar = .current) -> String {
        calendar.shortWeekdaySymbols[(day - 1) % 7]
    }

    static func summary(_ rule: ScheduleRule) -> String {
        switch rule {
        case .interval(let seconds):
            return tr("sched.rule.interval", max(seconds, ScheduleRule.minimumIntervalSeconds) / 60)
        case .fixedTime(let hour, let minute, let weekdays):
            let at = time(hour: hour, minute: minute)
            let valid = weekdays.filter { (1...7).contains($0) }
            if valid.isEmpty { return tr("sched.rule.daily", at) }
            let days = orderedWeekdays().filter { valid.contains($0) }.map { weekdayName($0) }.joined(separator: ", ")
            return tr("sched.rule.weekly", days, at)
        case .webhook:
            return tr("sched.rule.webhook")
        case .once(let at):
            return tr("automation.sched.rule.once", date(at))
        }
    }

    /// The stored reason as text: our own reasons are keys, the interrupted reason is a fixed phrase, the rest is what the
    /// session reported.
    static func error(_ task: ScheduledTask) -> String? {
        guard let error = task.lastError, !error.isEmpty else { return nil }
        if error == ScheduledTask.interruptedReason { return tr("sched.error.interrupted") }
        if error.hasPrefix("sched.") { return tr(error) }
        return error
    }

    /// Why a delivery came out as it did, for the Deliveries log.
    static func deliveryDetail(_ record: WebhookDeliveryRecord) -> String {
        let detail = record.detail ?? ""
        switch record.outcome {
        case .accepted: return detail.isEmpty ? tr("automation.hook.detail.accepted") : tr("automation.hook.detail.window", detail)
        case .filtered: return tr("automation.hook.detail.filtered", detail)
        case .duplicate: return tr("automation.hook.detail.duplicate", detail)
        case .coalesced: return tr("automation.hook.detail.coalesced", detail)
        case .queueFull: return tr("automation.hook.detail.queueFull")
        }
    }

    static func color(_ status: ScheduledRunStatus) -> Color {
        switch status {
        case .running: return NookTheme.amber
        case .succeeded: return NookTheme.mint
        case .failed: return NookTheme.coralSoft
        case .skipped: return NookTheme.textSecondary
        }
    }
}

// MARK: Editor

private struct ScheduledTaskEditor: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var settings = WorkspaceSettings.shared

    private enum Kind: String, CaseIterable, Identifiable {
        case interval, time, once, webhook
        var id: String { rawValue }
    }

    /// Where the runs go: each one a new session in a project, or all of them into one session.
    private enum Destination: String, CaseIterable, Identifiable {
        case newSession, session
        var id: String { rawValue }
    }

    let existing: ScheduledTask?
    let onDone: () -> Void

    @State private var title: String
    @State private var prompt: String
    @State private var path: String
    /// `@` in the prompt: people from your chats, and the files of the chosen project.
    @StateObject private var mentionModel = ComposerModel()
    private var mentionConfig: ComposerConfig { .mentions(folder: path) }
    @State private var provider: RunProvider
    @State private var kind: Kind
    @State private var minutes: Int
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var permission: PermissionPolicy
    @State private var onceAt: Date
    @State private var destination: Destination
    @State private var sessionID: UUID?
    @State private var fresh: Bool
    @State private var rules: WebhookRules
    @State private var showsDeliveries = false
    @StateObject private var secretCopied = CopiedMoment()

    init(existing: ScheduledTask?, onDone: @escaping () -> Void) {
        self.existing = existing
        self.onDone = onDone
        _title = State(initialValue: existing?.title ?? "")
        _prompt = State(initialValue: existing?.prompt ?? "")
        var path = "", provider = RunProvider.claude
        if case .newSession(let p, let name, _)? = existing?.target {
            path = p
            provider = RunProvider(rawValue: name) ?? .claude
        }
        var destination = Destination.newSession, sessionID: UUID?, fresh = false
        if case .existingSession(let id, let isFresh)? = existing?.target {
            destination = .session; sessionID = id; fresh = isFresh
        }
        _destination = State(initialValue: destination)
        _sessionID = State(initialValue: sessionID)
        _fresh = State(initialValue: fresh)
        _path = State(initialValue: path)
        _provider = State(initialValue: provider)
        _rules = State(initialValue: existing.map { ScheduledTaskStore.shared.webhookRules(for: $0.id) } ?? WebhookRules())
        var kind = Kind.interval, minutes = 60, hour = 9, minute = 0, days: Set<Int> = []
        // A new once-task starts at the next whole hour.
        var onceAt = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime)
            ?? Date().addingTimeInterval(3600)
        switch existing?.rule {
        case .interval(let seconds)?:
            minutes = max(1, seconds / 60)
        case .fixedTime(let h, let m, let d)?:
            kind = .time; hour = h; minute = m; days = d.filter { (1...7).contains($0) }
        case .webhook?:
            kind = .webhook
        case .once(let at)?:
            kind = .once; onceAt = at
        case nil:
            break
        }
        _kind = State(initialValue: kind)
        _minutes = State(initialValue: minutes)
        _time = State(initialValue: Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
        _weekdays = State(initialValue: days)
        _onceAt = State(initialValue: onceAt)
        _permission = State(initialValue: existing.map { ScheduledTaskStore.shared.permission(for: $0.id) } ?? .ask)
    }

    /// A form, in the sheet every dialog of Settings uses: Cancel and Save on the right.
    var body: some View {
        SetupSheet(title: existing == nil ? tr("sched.new") : tr("sched.edit"), subtitle: tr("sched.editor.subtitle"), width: 540) {
            SettingsTile(.automation, size: 48)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                field(tr("sched.field.name")) { TextField(tr("sched.field.namePlaceholder"), text: $title).textFieldStyle(.plain).modifier(FieldBox()) }
                field(tr("sched.field.prompt")) {
                    MentionSuggestions(model: mentionModel, text: $prompt, config: mentionConfig)
                    TextEditor(text: $prompt)
                        .font(NookTheme.TextStyle.body)
                        .scrollContentBackground(.hidden)
                        .mentions(mentionModel, text: $prompt, config: mentionConfig)
                        .frame(minHeight: 90)
                        .padding(NookTheme.Spacing.sm)
                        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
                }
                field(tr("automation.sched.destination")) { destinationPicker }
                if destination == .newSession {
                field(tr("sched.field.project")) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Text(path.isEmpty ? tr("sched.field.noProject") : AgentPathFormat.tilde(path))
                            .font(NookTheme.TextStyle.code)
                            .foregroundStyle(path.isEmpty ? NookTheme.textTertiary : NookTheme.paper)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(FieldBox())
                        SmallGhostButton(title: tr("sched.field.choose"), action: chooseFolder)
                    }
                }
                field(tr("sched.field.agent")) {
                    Picker("", selection: $provider) {
                        ForEach(providers) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240, alignment: .leading)
                }
                } else {
                    sessionPicker
                }
                field(tr("sched.field.schedule")) { scheduleEditor }
                if kind == .webhook {
                    webhookInfo
                    webhookRulesEditor
                    if let existing { deliveriesLog(existing.id) }
                    Text(tr("sched.permission.webhookNote"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                } else {
                    field(tr("sched.permission")) { permissionPicker }
                }
            }
        } footer: {
            Text(problem ?? "")
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.coralSoft)
            Spacer()
            Button(tr("button.cancel"), action: onDone)
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            Button(tr("sched.save"), action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.nookProminent)
                .controlSize(.large)
                .disabled(problem != nil)
        }
        .onChange(of: provider) {
            if !provider.capabilities.policies.contains(permission) { permission = .ask }
        }
    }

    // MARK: Parts

    private var providers: [RunProvider] {
        let connected = app.connectedProviders
        var list = connected.isEmpty ? RunProvider.allCases : connected
        if !list.contains(provider) { list.append(provider) }
        return list
    }

    private var scheduleEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $kind) {
                Text(tr("sched.kind.interval")).tag(Kind.interval)
                Text(tr("sched.kind.time")).tag(Kind.time)
                Text(tr("automation.sched.kind.once")).tag(Kind.once)
                Text(tr("sched.kind.webhook")).tag(Kind.webhook)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch kind {
            case .interval:
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("sched.interval.every")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    TextField("", value: $minutes, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .modifier(FieldBox())
                    Stepper("", value: $minutes, in: 1...100_000).labelsHidden()
                    Text(tr("sched.interval.minutes")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                }
                Text(tr("sched.interval.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            case .time:
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("sched.time.at")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                }
                HStack(spacing: NookTheme.Spacing.sm) {
                    ForEach(ScheduledTaskText.orderedWeekdays(), id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button {
                            if on { weekdays.remove(day) } else { weekdays.insert(day) }
                        } label: {
                            Text(ScheduledTaskText.weekdayName(day))
                                .font(NookTheme.TextStyle.strong)
                                .foregroundStyle(on ? NookTheme.onPrimary : NookTheme.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(NookTheme.shape(NookTheme.Radius.control).fill(on ? NookTheme.primary : NookTheme.field))
                        }
                        .buttonStyle(.nookPlain)
                    }
                }
                Text(tr("sched.weekdays.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
            case .once:
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("sched.time.at")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    DatePicker("", selection: $onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                }
                Text(tr("automation.sched.once.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .webhook:
                EmptyView()
            }
        }
    }

    // MARK: Destination

    /// The sessions a task can post into: this Mac's sessions that are not archived, newest first.
    private var sessions: [WorkspaceRun] {
        app.workspace.runs.filter { !$0.archived && !$0.isRemote }
    }

    private var destinationPicker: some View {
        Picker("", selection: $destination) {
            Text(tr("automation.sched.destination.new")).tag(Destination.newSession)
            Text(tr("automation.sched.destination.session")).tag(Destination.session)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 360, alignment: .leading)
    }

    @ViewBuilder
    private var sessionPicker: some View {
        field(tr("automation.sched.session")) {
            Picker("", selection: $sessionID) {
                Text(tr("automation.sched.session.choose")).tag(UUID?.none)
                ForEach(sessions) { run in
                    Text(run.title.isEmpty ? AgentPathFormat.tilde(run.workingDirectory) : run.title).tag(UUID?.some(run.id))
                }
                // A task whose session is gone keeps showing where it went, so saving does not move it by surprise.
                if let sessionID, !sessions.contains(where: { $0.id == sessionID }) {
                    Text(tr("automation.sched.session.gone")).tag(UUID?.some(sessionID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)
        }
        field(tr("automation.sched.conversation")) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Picker("", selection: $fresh) {
                    Text(tr("automation.sched.continue")).tag(false)
                    Text(tr("automation.sched.fresh")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360, alignment: .leading)
                Text(tr(fresh ? "automation.sched.fresh.hint" : "automation.sched.continue.hint"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Webhook rules

    private var webhookRulesEditor: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            Text(tr("automation.hook.placeholders"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            field(tr("automation.hook.filters")) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    ForEach($rules.filters) { $filter in
                        HStack(spacing: NookTheme.Spacing.sm) {
                            TextField(tr("automation.hook.filter.field"), text: $filter.field)
                                .textFieldStyle(.plain)
                                .modifier(FieldBox())
                            Picker("", selection: $filter.test) {
                                Text(tr("automation.hook.test.equals")).tag(WebhookFilter.Test.equals)
                                Text(tr("automation.hook.test.oneOf")).tag(WebhookFilter.Test.oneOf)
                                Text(tr("automation.hook.test.exists")).tag(WebhookFilter.Test.exists)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            if filter.test != .exists {
                                TextField(filter.test == .oneOf ? tr("automation.hook.filter.choices") : tr("automation.hook.filter.value"),
                                          text: $filter.value)
                                    .textFieldStyle(.plain)
                                    .modifier(FieldBox())
                            }
                            NookIconButton(systemName: "minus.circle", label: tr("automation.hook.filter.remove"), size: 24) {
                                rules.filters.removeAll { $0.id == filter.id }
                            }
                        }
                    }
                    SmallGhostButton(title: tr("automation.hook.filter.add")) {
                        rules.filters.append(WebhookFilter(field: "body.action", test: .equals))
                    }
                    Text(tr("automation.hook.filters.hint"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            field(tr("automation.hook.duplicateKey")) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    TextField("{{headers.x-github-delivery}}", text: $rules.duplicateKey)
                        .textFieldStyle(.plain)
                        .modifier(FieldBox())
                    Text(tr("automation.hook.duplicateKey.hint"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            field(tr("automation.hook.coalesce")) {
                VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Toggle(tr("automation.hook.coalesce.on"), isOn: Binding(
                            get: { rules.coalesceSeconds > 0 },
                            set: { rules.coalesceSeconds = $0 ? 120 : 0 }))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        if rules.coalesceSeconds > 0 {
                            TextField("", value: $rules.coalesceSeconds, format: .number)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 60)
                                .modifier(FieldBox())
                            Stepper("", value: $rules.coalesceSeconds, in: WebhookRules.coalesceRange, step: 10).labelsHidden()
                            Text(tr("automation.hook.coalesce.seconds")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                        }
                    }
                    Text(tr("automation.hook.coalesce.hint"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The latest deliveries of a saved webhook task: when, and what came of each.
    @ViewBuilder
    private func deliveriesLog(_ id: UUID) -> some View {
        let records = store.deliveries[id] ?? []
        DisclosureGroup(isExpanded: $showsDeliveries) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xs) {
                if records.isEmpty {
                    ListEmptyNote(tr("automation.hook.deliveries.empty"))
                }
                ForEach(records) { record in
                    HStack(alignment: .firstTextBaseline, spacing: NookTheme.Spacing.md) {
                        Text(ScheduledTaskText.date(record.receivedAt))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textTertiary)
                            .frame(width: 130, alignment: .leading)
                        Text(tr("automation.hook.outcome." + record.outcome.rawValue))
                            .font(NookTheme.TextStyle.label)
                            .foregroundStyle(record.outcome == .accepted ? NookTheme.mint : NookTheme.textSecondary)
                            .frame(width: 90, alignment: .leading)
                        Text(ScheduledTaskText.deliveryDetail(record))
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(2)
                            .help(record.deliveryID)
                    }
                }
            }
            .padding(.top, NookTheme.Spacing.sm)
        } label: {
            Text(tr("automation.hook.deliveries", records.count))
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private var permissionPicker: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Picker("", selection: $permission) {
                ForEach(provider.capabilities.policies.filter(\.isUnattendedSafe)) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)
            Text(permission == .bypass ? tr("sched.permission.bypassWarning") : tr("sched.permission.hint"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(permission == .bypass ? NookTheme.amber : NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var webhookInfo: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if let existing, existing.rule.isWebhook {
                if let url = store.webhookURL(for: existing.id) {
                    field(tr("sched.webhook.url")) {
                        HStack(spacing: NookTheme.Spacing.md) {
                            Text(url).font(NookTheme.mono(11)).foregroundStyle(NookTheme.paper)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).modifier(FieldBox())
                            SmallGhostButton(title: tr("sched.webhook.copy")) { Pasteboard.copy(url) }
                        }
                    }
                } else {
                    Text(tr("sched.webhook.noPort")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.amber)
                }
                if WorkspaceSettings.shared.scheduledWebhooksPublic, let url = WebhookRelayClient.shared.publicURL(for: existing.id) {
                    field(tr("sched.public.url")) {
                        HStack(spacing: NookTheme.Spacing.md) {
                            Text(url).font(NookTheme.mono(11)).foregroundStyle(NookTheme.paper)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).modifier(FieldBox())
                            SmallGhostButton(title: tr("sched.webhook.copy")) { Pasteboard.copy(url) }
                        }
                    }
                }
                HStack(spacing: NookTheme.Spacing.md) {
                    SmallGhostButton(title: secretCopied.copied ? tr("sched.webhook.copied") : tr("sched.webhook.copySecret")) {
                        if let secret = store.webhookSecret(for: existing.id, create: true) { secretCopied.copy(secret) }
                    }
                    SmallGhostButton(title: tr("sched.webhook.rotate")) {
                        if let secret = store.rotateWebhookSecret(existing.id) { secretCopied.copy(secret) }
                    }
                }
            } else {
                Text(tr("sched.webhook.afterSave")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary)
            }
            Text(tr("sched.webhook.hint"))
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(label).font(NookTheme.TextStyle.strong).foregroundStyle(NookTheme.textTertiary)
            content()
        }
    }

    // MARK: Actions

    private var problem: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return tr("sched.invalid.prompt") }
        switch destination {
        case .newSession:
            if path.isEmpty || !FileManager.default.fileExists(atPath: path) { return tr("sched.invalid.project") }
        case .session:
            if sessionID == nil { return tr("automation.sched.invalid.session") }
        }
        // A once-task whose moment passed is fine when it is unchanged (it ran, or runs when the Mac wakes).
        if kind == .once, onceAt <= Date(), existing?.rule != .once(at: onceAt) { return tr("automation.sched.invalid.past") }
        if kind == .webhook, rules.filters.contains(where: { $0.field.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return tr("automation.hook.invalid.filter")
        }
        if kind == .interval, minutes < 1 { return tr("sched.invalid.interval") }
        return nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("ws.new.choosePrompt")
        panel.message = tr("ws.new.chooseMessage")
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runAboveNotch() == .OK, let url = panel.url else { return }
        path = url.path
    }

    private func save() {
        guard problem == nil else { return }
        let rule: ScheduleRule
        switch kind {
        case .interval:
            rule = .interval(seconds: max(1, minutes) * 60)
        case .time:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            rule = .fixedTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays)
        case .webhook:
            rule = .webhook
        case .once:
            rule = .once(at: onceAt)
        }
        var profileID: String?
        if case .newSession(_, let name, let id)? = existing?.target, name == provider.rawValue { profileID = id }
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map { String($0.prefix(60)) } ?? ""
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = ScheduledTask(
            id: existing?.id ?? UUID(),
            title: name.isEmpty ? firstLine : name,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            rule: rule,
            target: target(profileID: profileID),
            enabled: existing?.enabled ?? true,
            createdAt: existing?.createdAt ?? Date()
        )
        var cleaned = rules
        cleaned.filters = rules.filters.map { var f = $0; f.field = f.field.trimmingCharacters(in: .whitespaces); return f }
        cleaned.duplicateKey = rules.duplicateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.coalesceSeconds > 0 {
            cleaned.coalesceSeconds = min(max(cleaned.coalesceSeconds, WebhookRules.coalesceRange.lowerBound), WebhookRules.coalesceRange.upperBound)
        }
        store.save(task, permission: kind == .webhook ? .ask : permission, webhook: kind == .webhook ? cleaned : WebhookRules())
        onDone()
    }

    private func target(profileID: String?) -> ScheduledTaskTarget {
        switch destination {
        case .newSession: return .newSession(projectPath: path, provider: provider.rawValue, profileID: profileID)
        case .session: return .existingSession(id: sessionID ?? UUID(), fresh: fresh)
        }
    }
}

/// The padded dark box the editor's fields sit in.
private struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(NookTheme.TextStyle.body)
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .roundedBackground(NookTheme.field, radius: NookTheme.Radius.control)
    }
}
