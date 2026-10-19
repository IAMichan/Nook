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
    @State private var notice: String?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        var existing: ScheduledTask?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !settings.scheduledTasksEnabled { banner(tr("sched.disabledGlobal"), color: NookTheme.amber) }
            if case .failed(let message) = listener.state { banner(tr("sched.webhook.failed", message), color: NookTheme.coralSoft) }
            if let notice { banner(notice, color: NookTheme.textSecondary) }
            if store.tasks.isEmpty {
                Spacer(minLength: 0)
                Text(tr("sched.empty"))
                    .font(NookTheme.font(13))
                    .foregroundStyle(NookTheme.textTertiary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.tasks) { task in
                            TaskRow(task: task,
                                    running: store.isRunning(task.id),
                                    canRun: settings.scheduledTasksEnabled,
                                    toggle: { store.setEnabled(task.id, $0) },
                                    runNow: { run(task) },
                                    edit: { editing = EditorTarget(existing: task) },
                                    delete: { deleting = task })
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 420, idealHeight: 520)
        .background(NookTheme.graphite)
        .preferredColorScheme(.dark)
        .sheet(item: $editing) { target in
            ScheduledTaskEditor(existing: target.existing) { editing = nil }
                .environmentObject(app)
        }
        .confirmationDialog(deleting.map { tr("sched.delete.confirm", $0.title) } ?? "", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button(tr("sched.delete"), role: .destructive) {
                if let task = deleting { store.delete(task.id) }
                deleting = nil
            }
            Button(tr("button.cancel"), role: .cancel) { deleting = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(tr("sched.title"))
                .font(NookTheme.font(18, .semibold))
                .foregroundStyle(NookTheme.paper)
            Spacer()
            SmallGhostButton(title: tr("sched.new")) { editing = EditorTarget(existing: nil) }
            NookIconButton(systemName: "xmark", label: tr("button.cancel"), size: 28, action: onClose)
        }
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(NookTheme.font(12))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
    }

    private func run(_ task: ScheduledTask) {
        switch store.runNow(task.id) {
        case .started: notice = nil
        case .busy: notice = tr("sched.busy", task.title)
        case .notAvailable: notice = tr("sched.disabledGlobal")
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
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.title.isEmpty ? tr("sched.untitled") : task.title)
                    .font(NookTheme.font(14, .semibold))
                    .foregroundStyle(task.enabled ? NookTheme.paper : NookTheme.textSecondary)
                    .lineLimit(1)
                Text(ScheduledTaskText.summary(task.rule))
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.textSecondary)
                HStack(spacing: 8) {
                    statusChip
                    Text(timing)
                        .font(NookTheme.font(11))
                        .foregroundStyle(NookTheme.textTertiary)
                        .lineLimit(1)
                }
                if let error = ScheduledTaskText.error(task), !running {
                    Text(error)
                        .font(NookTheme.font(11))
                        .foregroundStyle(task.lastStatus == .failed ? NookTheme.coralSoft : NookTheme.textTertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
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
                    .padding(.leading, 6)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(NookTheme.smoke.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NookTheme.line2, lineWidth: 1))
    }

    private var effectiveStatus: ScheduledRunStatus? { running ? .running : task.lastStatus }

    @ViewBuilder
    private var statusChip: some View {
        if let status = effectiveStatus {
            let color = ScheduledTaskText.color(status)
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(tr("sched.status." + status.rawValue))
                    .font(NookTheme.font(11, .semibold))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
        } else {
            Text(tr("sched.never"))
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.textTertiary)
        }
    }

    private var timing: String {
        var parts: [String] = []
        if let last = task.lastRun { parts.append(tr("sched.last", ScheduledTaskText.date(last))) }
        if task.enabled, let next = task.nextRun, !running { parts.append(tr("sched.next", ScheduledTaskText.date(next))) }
        if task.enabled, task.rule.isWebhook { parts.append(tr("sched.waitingWebhook")) }
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
        case interval, time, webhook
        var id: String { rawValue }
    }

    let existing: ScheduledTask?
    let onDone: () -> Void

    @State private var title: String
    @State private var prompt: String
    @State private var path: String
    @State private var provider: RunProvider
    @State private var kind: Kind
    @State private var minutes: Int
    @State private var time: Date
    @State private var weekdays: Set<Int>
    @State private var permission: PermissionPolicy
    @State private var secretCopied = false

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
        _path = State(initialValue: path)
        _provider = State(initialValue: provider)
        var kind = Kind.interval, minutes = 60, hour = 9, minute = 0, days: Set<Int> = []
        switch existing?.rule {
        case .interval(let seconds)?:
            minutes = max(1, seconds / 60)
        case .fixedTime(let h, let m, let d)?:
            kind = .time; hour = h; minute = m; days = d.filter { (1...7).contains($0) }
        case .webhook?:
            kind = .webhook
        case nil:
            break
        }
        _kind = State(initialValue: kind)
        _minutes = State(initialValue: minutes)
        _time = State(initialValue: Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date())
        _weekdays = State(initialValue: days)
        _permission = State(initialValue: existing.map { ScheduledTaskStore.shared.permission(for: $0.id) } ?? .ask)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? tr("sched.new") : tr("sched.edit"))
                .font(NookTheme.font(18, .semibold))
                .foregroundStyle(NookTheme.paper)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field(tr("sched.field.name")) { TextField(tr("sched.field.namePlaceholder"), text: $title).textFieldStyle(.plain).modifier(FieldBox()) }
                    field(tr("sched.field.prompt")) {
                        TextEditor(text: $prompt)
                            .font(NookTheme.font(13))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
                    }
                    field(tr("sched.field.project")) {
                        HStack(spacing: 8) {
                            Text(path.isEmpty ? tr("sched.field.noProject") : AgentPathFormat.tilde(path))
                                .font(NookTheme.mono(12))
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
                    field(tr("sched.field.schedule")) { scheduleEditor }
                    if kind == .webhook {
                        webhookInfo
                        Text(tr("sched.permission.webhookNote"))
                            .font(NookTheme.font(11))
                            .foregroundStyle(NookTheme.textTertiary)
                    } else {
                        field(tr("sched.permission")) { permissionPicker }
                    }
                }
            }
            HStack {
                Text(problem ?? "")
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.coralSoft)
                Spacer()
                NookGhostButton(title: tr("button.cancel"), action: onDone)
                NookPrimaryButton(title: tr("sched.save"), action: save)
                    .opacity(problem == nil ? 1 : 0.4)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 540, height: 640)
        .background(NookTheme.graphite)
        .preferredColorScheme(.dark)
        .onChange(of: provider) { _ in
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
                Text(tr("sched.kind.webhook")).tag(Kind.webhook)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch kind {
            case .interval:
                HStack(spacing: 8) {
                    Text(tr("sched.interval.every")).font(NookTheme.font(13)).foregroundStyle(NookTheme.textSecondary)
                    TextField("", value: $minutes, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .modifier(FieldBox())
                    Stepper("", value: $minutes, in: 1...100_000).labelsHidden()
                    Text(tr("sched.interval.minutes")).font(NookTheme.font(13)).foregroundStyle(NookTheme.textSecondary)
                }
                Text(tr("sched.interval.hint")).font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
            case .time:
                HStack(spacing: 8) {
                    Text(tr("sched.time.at")).font(NookTheme.font(13)).foregroundStyle(NookTheme.textSecondary)
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                }
                HStack(spacing: 6) {
                    ForEach(ScheduledTaskText.orderedWeekdays(), id: \.self) { day in
                        let on = weekdays.contains(day)
                        Button {
                            if on { weekdays.remove(day) } else { weekdays.insert(day) }
                        } label: {
                            Text(ScheduledTaskText.weekdayName(day))
                                .font(NookTheme.font(12, .semibold))
                                .foregroundStyle(on ? NookTheme.ink : NookTheme.textSecondary)
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Capsule().fill(on ? NookTheme.paper : NookTheme.field))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(tr("sched.weekdays.hint")).font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
            case .webhook:
                EmptyView()
            }
        }
    }

    private var permissionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $permission) {
                ForEach(provider.capabilities.policies.filter { $0 != .bypass }) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240, alignment: .leading)
            Text(permission == .bypass ? tr("sched.permission.bypassWarning") : tr("sched.permission.hint"))
                .font(NookTheme.font(11))
                .foregroundStyle(permission == .bypass ? NookTheme.amber : NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var webhookInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let existing, existing.rule.isWebhook {
                if let url = store.webhookURL(for: existing.id) {
                    field(tr("sched.webhook.url")) {
                        HStack(spacing: 8) {
                            Text(url).font(NookTheme.mono(11)).foregroundStyle(NookTheme.paper)
                                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).modifier(FieldBox())
                            SmallGhostButton(title: tr("sched.webhook.copy")) { copy(url) }
                        }
                    }
                } else {
                    Text(tr("sched.webhook.noPort")).font(NookTheme.font(12)).foregroundStyle(NookTheme.amber)
                }
                HStack(spacing: 8) {
                    SmallGhostButton(title: secretCopied ? tr("sched.webhook.copied") : tr("sched.webhook.copySecret")) {
                        if let secret = store.webhookSecret(for: existing.id, create: true) { copy(secret); secretCopied = true }
                    }
                    SmallGhostButton(title: tr("sched.webhook.rotate")) {
                        if let secret = store.rotateWebhookSecret(existing.id) { copy(secret); secretCopied = true }
                    }
                }
            } else {
                Text(tr("sched.webhook.afterSave")).font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary)
            }
            Text(tr("sched.webhook.hint"))
                .font(NookTheme.font(11))
                .foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(NookTheme.font(12, .semibold)).foregroundStyle(NookTheme.textTertiary)
            content()
        }
    }

    // MARK: Actions

    private var problem: String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return tr("sched.invalid.prompt") }
        if path.isEmpty || !FileManager.default.fileExists(atPath: path) { return tr("sched.invalid.project") }
        if kind == .interval, minutes < 1 { return tr("sched.invalid.interval") }
        return nil
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = tr("ws.new.choosePrompt")
        panel.message = tr("ws.new.chooseMessage")
        if !path.isEmpty { panel.directoryURL = URL(fileURLWithPath: path) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
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
            target: .newSession(projectPath: path, provider: provider.rawValue, profileID: profileID),
            enabled: existing?.enabled ?? true,
            createdAt: existing?.createdAt ?? Date()
        )
        store.save(task, permission: kind == .webhook ? .ask : permission)
        onDone()
    }
}

/// The padded dark box the editor's fields sit in.
private struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(NookTheme.font(13))
            .foregroundStyle(NookTheme.paper)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(NookTheme.field))
    }
}
