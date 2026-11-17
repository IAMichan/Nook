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

    /// Every task of the secretary is there already.
    private var hasSecretary: Bool {
        NookSchedule.secretary().allSatisfy { draft in draft.preset.map(store.hasPreset) ?? false }
    }

    private struct EditorTarget: Identifiable {
        let id = UUID()
        var existing: ScheduledTask?
    }

    var body: some View {
        // The one sheet shape of Settings: what this is on top, the tasks in the middle, New task and Done below.
        SetupSheet(title: tr("sched.title"), subtitle: tr("sched.subtitle"), width: 620) {
            SettingsTile(.automation, size: 40)
        } content: {
            // Nook's own tasks run without the switch for agent tasks; the banner is for the agent tasks it holds back.
            if !settings.scheduledTasksEnabled, store.tasks.contains(where: { !$0.target.isNook }) {
                banner(tr("sched.disabledGlobal"), color: NookTheme.amber)
            }
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
                                canRun: store.mayRun(task),
                                toggle: { store.setEnabled(task.id, $0) },
                                runNow: { run(task) },
                                edit: { editing = EditorTarget(existing: task) },
                                delete: { deleting = task })
                            .contextMenu {
                                Button(tr("sched.runNow")) { run(task) }
                                    .disabled(!store.mayRun(task) || store.isRunning(task.id))
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
            // The personal secretary in one click: a morning briefing, a quiet midday check and a wrap-up for Nook Chat.
            if !hasSecretary {
                Button(tr("automation.secretary.add")) { AppModel.addSecretary() }
                    .controlSize(.large)
                    .nookTip(tr("automation.secretary.help"))
            }
            Spacer()
            Button(tr("settings2.done"), action: onClose)
                .sheetPrimaryButton()
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
                NookIconButton(systemName: "pencil", label: tr("sched.edit"), size: 28, action: edit)
                NookIconButton(systemName: "trash", label: tr("sched.delete"), size: 28, action: delete)
                Toggle(tr("sched.enabled"), isOn: Binding(get: { task.enabled }, set: toggle))
                    .labelsHidden()
                    .compactSwitch()
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
        if task.enabled, task.rule.isMessage { parts.append(tr("automation.sched.waitingMessage")) }
        if task.isDone { parts.append(tr("automation.sched.done")) }
        if task.target.sessionID != nil {
            parts.append(tr(task.target.freshConversation ? "automation.sched.fresh" : "automation.sched.continue"))
        }
        if task.target.isNook { parts.append(tr("automation.sched.destination.nook")) }
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

    /// In the app's language, not the Mac's: the list and the approval line read in the language Nook speaks.
    static func weekdayName(_ day: Int, _ calendar: Calendar = .current) -> String {
        var named = calendar
        named.locale = Locale(identifier: I18n.shared.currentLanguage.rawValue)
        return named.shortWeekdaySymbols[(day - 1) % 7]
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
        case .message(let trigger):
            return messageSummary(trigger)
        }
    }

    /// The apps a message trigger can listen to, as the chat inbox names them, with their names.
    static var messageApps: [(id: String, name: String)] { [
        ("whatsapp", "WhatsApp"), ("messages", tr("automation.app.messages")), ("mail", tr("automation.app.mail")), ("telegram", "Telegram"), ("slack", "Slack"),
        ("teams", "Teams"), ("signal", "Signal"), ("instagram", "Instagram"), ("messenger", "Messenger"), ("linkedin", "LinkedIn"),
        ("discord", "Discord"), ("snapchat", "Snapchat")
    ] }

    /// "On a new message · WhatsApp, Mail · from Lisa · about invoice" for the list and the approval card.
    static func messageSummary(_ trigger: MessageTrigger) -> String {
        var parts = [tr("automation.sched.rule.message")]
        if !trigger.apps.isEmpty {
            parts.append(trigger.apps.map { id in messageApps.first { $0.id == id }?.name ?? id }.joined(separator: ", "))
        }
        if !trigger.from.isEmpty { parts.append(tr("automation.sched.rule.from", trigger.from)) }
        if !trigger.keywords.isEmpty { parts.append(tr("automation.sched.rule.about", trigger.keywords.joined(separator: ", "))) }
        if trigger.groups { parts.append(tr("automation.sched.rule.groups")) }
        return parts.joined(separator: " · ")
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

/// The editor for one scheduled task, in Settings and in the Nook tab (`forNook`: a new task goes to Nook Chat).
struct ScheduledTaskEditor: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var store = ScheduledTaskStore.shared
    @ObservedObject private var settings = WorkspaceSettings.shared

    private enum Kind: String, CaseIterable, Identifiable {
        case interval, time, once, webhook, message
        var id: String { rawValue }
    }

    /// Where the runs go: each one a new session in a project, all of them into one session, or Nook Chat itself (each run
    /// a conversation of its own, with drafts and plans that wait for the user).
    private enum Destination: String, CaseIterable, Identifiable {
        case newSession, session, nook
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .newSession: return "automation.sched.destination.new"
            case .session: return "automation.sched.destination.session"
            case .nook: return "automation.sched.destination.nook"
            }
        }

        var symbol: String {
            switch self {
            case .newSession: return "plus.bubble"
            case .session: return "square.stack"
            case .nook: return "sparkles"
            }
        }
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
    /// Nook Chat only speaks up when something new needs the user.
    @State private var quiet: Bool
    /// What a run of Nook's carries out by itself once it prepared the steps.
    @State private var autonomy: NookAutonomy
    /// A message trigger: which apps (empty: all), from whom, about what, and whether group chats count.
    @State private var messageApps: Set<String>
    @State private var messageFrom: String
    @State private var messageWords: String
    @State private var messageGroups: Bool
    @State private var rules: WebhookRules
    @State private var showsDeliveries = false
    @StateObject private var secretCopied = CopiedMoment()

    init(existing: ScheduledTask?, forNook: Bool = false, onDone: @escaping () -> Void) {
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
        if existing?.target.isNook == true || (existing == nil && forNook) { destination = .nook }
        _destination = State(initialValue: destination)
        _sessionID = State(initialValue: sessionID)
        _fresh = State(initialValue: fresh)
        _quiet = State(initialValue: existing.map { ScheduledTaskStore.shared.isQuiet($0.id) } ?? false)
        _autonomy = State(initialValue: existing.map { ScheduledTaskStore.shared.autonomy(for: $0.id) } ?? .ask)
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
        case .message?:
            kind = .message
        case nil:
            break
        }
        // A new task for Nook starts as a time of day ("every morning at 9:00"), what people ask Nook for most.
        if existing == nil && forNook { kind = .time }
        let trigger = existing?.rule.messageTrigger ?? MessageTrigger()
        _messageApps = State(initialValue: Set(trigger.apps))
        _messageFrom = State(initialValue: trigger.from)
        _messageWords = State(initialValue: trigger.keywords.joined(separator: ", "))
        _messageGroups = State(initialValue: trigger.groups)
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
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xl) {
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
                } else if destination == .session {
                    sessionPicker
                } else {
                    quietRow
                    autonomyRow
                }
                field(tr("sched.field.schedule")) { scheduleEditor }
                if kind == .webhook {
                    webhookInfo
                    webhookRulesEditor
                    if let existing { deliveriesLog(existing.id) }
                    Text(tr("sched.permission.webhookNote"))
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textTertiary)
                } else if destination != .nook {
                    // Nook proposes and drafts; what it would do waits for the user in the chat, so it has no rights to pick.
                    field(tr("sched.permission")) { permissionPicker }
                }
            }
        } footer: {
            InlineErrorText(problem ?? "")
            Spacer()
            Button(tr("button.cancel"), action: onDone)
                .sheetCancelButton()
            Button(tr("sched.save"), action: save)
                .sheetPrimaryButton()
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
            // Chips that wrap instead of a segmented control: with Nook Chat's fifth choice a segmented control is
            // wider than the sheet in every language and pushes the whole form past its edges.
            ChipFlow(spacing: NookTheme.Spacing.sm) {
                ForEach(kinds) { option in
                    NookFilterChip(title: kindTitle(option), selected: kind == option) { kind = option }
                }
            }
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
                    .fixedSize(horizontal: false, vertical: true)
            case .time:
                VStack(alignment: .leading, spacing: NookTheme.Spacing.lg) {
                    HStack(spacing: NookTheme.Spacing.md) {
                        Text(tr("sched.time.at")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                        DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                        Spacer(minLength: NookTheme.Spacing.md)
                        // What the choice comes down to, in the words the task list uses.
                        Label(ScheduledTaskText.summary(timeRule), icon: "clock")
                            .font(NookTheme.TextStyle.detail)
                            .foregroundStyle(NookTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    WeekdayStrip(selection: $weekdays)
                }
                .padding(NookTheme.Spacing.lg)
                .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.field))
                .overlay(NookTheme.shape(NookTheme.Radius.control).stroke(NookTheme.fieldStroke, lineWidth: 1))
                Text(tr("sched.weekdays.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .once:
                HStack(spacing: NookTheme.Spacing.md) {
                    Text(tr("sched.time.at")).font(NookTheme.TextStyle.body).foregroundStyle(NookTheme.textSecondary)
                    DatePicker("", selection: $onceAt, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                }
                Text(tr("automation.sched.once.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .webhook:
                EmptyView()
            case .message:
                messageEditor
            }
        }
    }

    /// The fixed-time rule as the form stands, for the summary beside the time.
    private var timeRule: ScheduleRule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        return .fixedTime(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: weekdays)
    }

    /// The ways a task can start. Waiting for a message is for Nook Chat, which reads the chat and prepares the answer.
    private var kinds: [Kind] {
        Kind.allCases.filter { $0 != .message || destination == .nook }
    }

    private func kindTitle(_ kind: Kind) -> String {
        switch kind {
        case .interval: return tr("sched.kind.interval")
        case .time: return tr("sched.kind.time")
        case .once: return tr("automation.sched.kind.once")
        case .webhook: return tr("sched.kind.webhook")
        case .message: return tr("automation.sched.kind.message")
        }
    }

    private var messageEditor: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            ChipFlow(spacing: NookTheme.Spacing.sm) {
                ForEach(ScheduledTaskText.messageApps, id: \.id) { app in
                    let on = messageApps.contains(app.id)
                    NookFilterChip(title: app.name, selected: on) {
                        if on { messageApps.remove(app.id) } else { messageApps.insert(app.id) }
                    }
                }
            }
            Text(tr("automation.sched.message.apps.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(tr("automation.sched.message.from"), text: $messageFrom).textFieldStyle(.plain).modifier(FieldBox())
            TextField(tr("automation.sched.message.words"), text: $messageWords).textFieldStyle(.plain).modifier(FieldBox())
            Toggle(tr("automation.sched.message.groups"), isOn: $messageGroups).compactSwitch()
            Text(tr("automation.sched.message.hint")).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Destination

    /// The sessions a task can post into: this Mac's sessions that are not archived, newest first.
    private var sessions: [WorkspaceRun] {
        app.workspace.runs.filter { !$0.archived && !$0.isRemote }
    }

    /// Three cards of one width side by side, so a long label wraps instead of pushing the sheet wider, and the line
    /// under them says what the chosen one does.
    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            HStack(spacing: NookTheme.Spacing.md) {
                ForEach(Destination.allCases) { option in
                    DestinationCard(symbol: option.symbol, title: tr(option.titleKey), selected: destination == option) {
                        withAnimation(NookTheme.Motion.quick) { destination = option }
                    }
                }
            }
            if destination == .nook {
                Text(tr("automation.sched.nook.hint"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Nook Chat's one setting: a row with the switch on the right and what it does under the title.
    private var quietRow: some View {
        HStack(alignment: .top, spacing: NookTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.xxs) {
                Text(tr("automation.sched.quiet"))
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(NookTheme.paper)
                Text(tr("automation.sched.quiet.hint"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: $quiet)
                .labelsHidden()
                .compactSwitch()
                .accessibilityLabel(tr("automation.sched.quiet"))
        }
        .padding(NookTheme.Spacing.lg)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
    }

    /// What Nook Chat carries out by itself after a run: the three levels side by side, what the chosen one does under them.
    private var autonomyRow: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Text(tr("autonomy.field"))
                .font(NookTheme.TextStyle.strong)
                .foregroundStyle(NookTheme.paper)
            Picker("", selection: $autonomy) {
                ForEach(NookAutonomy.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel(tr("autonomy.field"))
            Text(autonomy.detail)
                .font(NookTheme.TextStyle.detail)
                .foregroundStyle(autonomy == .auto ? NookTheme.amber : NookTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if autonomy != .ask {
                Text(tr(kind == .message || kind == .webhook ? "autonomy.hint.outside" : "autonomy.hint.limits"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NookTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .roundedBackground(NookTheme.field, radius: NookTheme.Radius.card)
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
                            .compactSwitch()
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
                            .nookTip(record.deliveryID)
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
        case .nook:
            if kind == .interval, minutes < NookSchedule.minimumMinutes { return tr("automation.sched.invalid.nookInterval", NookSchedule.minimumMinutes) }
        }
        // A once-task whose moment passed is fine when it is unchanged (it ran, or runs when the Mac wakes).
        if kind == .once, onceAt <= Date(), existing?.rule != .once(at: onceAt) { return tr("automation.sched.invalid.past") }
        if kind == .webhook, rules.filters.contains(where: { $0.field.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return tr("automation.hook.invalid.filter")
        }
        if kind == .interval, minutes < 1 { return tr("sched.invalid.interval") }
        if kind == .message, destination != .nook { return tr("automation.sched.invalid.messageNook") }
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
        case .message:
            rule = .message(MessageTrigger(apps: messageApps.sorted(), from: messageFrom,
                                           keywords: messageWords.components(separatedBy: ","), groups: messageGroups))
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
        store.save(task, permission: kind == .webhook || destination == .nook ? .ask : permission, webhook: kind == .webhook ? cleaned : WebhookRules(),
                   quiet: destination == .nook && quiet, autonomy: destination == .nook ? autonomy : .ask)
        onDone()
    }

    private func target(profileID: String?) -> ScheduledTaskTarget {
        switch destination {
        case .newSession: return .newSession(projectPath: path, provider: provider.rawValue, profileID: profileID)
        case .session: return .existingSession(id: sessionID ?? UUID(), fresh: fresh)
        case .nook: return .nook
        }
    }
}

/// One choice of where a task's runs go: a symbol over its name, the chosen one outlined on the accent.
private struct DestinationCard: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = NookTheme.shape(NookTheme.Radius.card)
        Button(action: action) {
            VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
                Image(icon: symbol)
                    .font(NookTheme.TextStyle.body)
                    .foregroundStyle(selected ? NookTheme.iris : NookTheme.textTertiary)
                Text(title)
                    .font(NookTheme.TextStyle.strong)
                    .foregroundStyle(selected ? NookTheme.paper : NookTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(NookTheme.Spacing.lg)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(shape.fill(selected ? NookTheme.iris.opacity(0.12) : (hovered ? NookTheme.paper.opacity(0.06) : NookTheme.field)))
            .overlay(shape.stroke(selected ? NookTheme.iris.opacity(0.8) : NookTheme.fieldStroke, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.nookPlain)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The days of the week as one segmented track, in the order the user's week starts: equal cells, the chosen ones on
/// the accent. None chosen means every day, so then every cell reads as included, quieter than a chosen one.
private struct WeekdayStrip: View {
    @Binding var selection: Set<Int>
    @State private var hovered: Int?

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xxs) {
            ForEach(ScheduledTaskText.orderedWeekdays(), id: \.self) { day in
                let on = selection.contains(day)
                Button {
                    if on { selection.remove(day) } else { selection.insert(day) }
                } label: {
                    Text(ScheduledTaskText.weekdayName(day))
                        .font(NookTheme.TextStyle.label)
                        .foregroundStyle(on ? NookTheme.onIris : (selection.isEmpty || hovered == day ? NookTheme.textStrong : NookTheme.textTertiary))
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(NookTheme.shape(NookTheme.Radius.control).fill(on ? NookTheme.iris : (hovered == day ? NookTheme.smoke : .clear)))
                        .contentShape(NookTheme.shape(NookTheme.Radius.control))
                }
                .buttonStyle(.nookPlain)
                .onHover { hovered = $0 ? day : (hovered == day ? nil : hovered) }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(NookTheme.Spacing.xxs)
        .background(NookTheme.shape(NookTheme.Radius.control).fill(NookTheme.surface))
        .animation(NookTheme.hover, value: hovered)
        .animation(NookTheme.hover, value: selection)
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
