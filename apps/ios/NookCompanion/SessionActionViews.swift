import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The Agents tab as on the Mac (`CompanionFeature.agentsTab`, packages/protocol/Sources/CompanionSessions.swift): the
// session menus in the Mac's order, the prompts they ask first, the composer's effort, mode and model, the messages in
// line, several questions at once, and a file for a new session.

// MARK: Menus

/// A session action that asks first, shown by `RootView` (`SessionPromptHost`).
struct SessionPrompt: Identifiable {
    enum Kind { case rename, delete, end }
    let session: SessionDigest
    let kind: Kind
    var id: String { session.id + "\(kind)" }
}

/// What you can do with a session, as the Mac's row menu (`SessionMenu.row`) or its header (`SessionMenu.header`)
/// offers it, from the actions the Mac lists for it. Rename, delete and end ask first (`SessionPrompt`); a fork opens
/// the new session.
struct SessionActionsMenu: View {
    enum Place { case row, header }

    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let place: Place

    private var offered: Set<SessionAction> {
        guard client.can(CompanionFeature.manage) else { return [] }
        return Set((session.actions ?? []).compactMap(SessionAction.init(rawValue:)))
    }

    var body: some View {
        let offered = offered
        switch place {
        case .row:
            Section {
                ForEach([SessionAction.rename, .pin, .unpin, .settle, .reopen].filter(offered.contains), id: \.self) { button($0) }
                snooze(offered)
            }
            Section {
                ForEach([SessionAction.fork, .restartAgent, .markUnread, .mainThreadOn, .mainThreadOff].filter(offered.contains), id: \.self) { button($0) }
            }
            Section {
                copyMenu
                ForEach([SessionAction.archive, .delete, .end].filter(offered.contains), id: \.self) { button($0) }
            }
        case .header:
            Section {
                ForEach([SessionAction.retry, .settle, .reopen].filter(offered.contains), id: \.self) { button($0) }
            }
            // Its parent, forks, delegated tasks and side chats, as the Lineage control in the Mac's header.
            Section { LineageMenu(session: session) }
            Section {
                ForEach([SessionAction.rename, .regenerateTitle, .fork, .restartAgent, .mainThreadOn, .mainThreadOff]
                    .filter(offered.contains), id: \.self) { button($0) }
            }
            Section {
                ForEach([SessionAction.pin, .unpin].filter(offered.contains), id: \.self) { button($0) }
                snooze(offered)
                if offered.contains(.markUnread) { button(.markUnread) }
                copyMenu
            }
            Section {
                ForEach([SessionAction.archive, .delete, .end].filter(offered.contains), id: \.self) { button($0) }
            }
        }
    }

    /// Snooze as one submenu, or Cancel snooze while it sleeps.
    @ViewBuilder
    private func snooze(_ offered: Set<SessionAction>) -> some View {
        if offered.contains(.unsnooze) {
            Button { run(.unsnooze) } label: { Label("Cancel snooze", systemImage: "alarm") }
        } else if offered.contains(.snoozeHour) {
            Menu {
                Button("One hour") { run(.snoozeHour) }
                Button("This evening") { run(.snoozeEvening) }
                Button("Tomorrow morning") { run(.snoozeTomorrow) }
                SnoozeCustomItems(session: session, actions: Array(offered)) { run($0) }
            } label: { Label("Snooze", systemImage: "clock") }
        }
    }

    /// "Copy" with the conversation, the session's folder, branch and id, as on the Mac.
    private var copyMenu: some View {
        Menu {
            if place == .header, !conversation.isEmpty {
                Button("Conversation") { copy(markdown) }
                // The Mac's "Save as Markdown", the phone's way: to Files, Notes or a message through the share sheet.
                ShareLink(item: markdown, preview: SharePreview(session.title)) {
                    Label("Share as Markdown", systemImage: "square.and.arrow.up")
                }
            }
            Button("Path") { copy(session.path ?? session.folder) }
            if let branch = session.branch, !branch.isEmpty { Button("Branch") { copy(branch) } }
            Button("Session ID") { copy(session.id) }
        } label: { Label("Copy", systemImage: "doc.on.doc") }
    }

    private var conversation: [TimelineEntry] { client.conversation(session.id) }

    /// What the phone has of the conversation as Markdown, as the Mac's "Copy conversation" writes it.
    private var markdown: String {
        SessionMarkdown.markdown(title: session.title, agent: session.agent, folder: session.folder, branch: session.branch,
                                 entries: conversation, you: String(localized: "You"))
    }

    @ViewBuilder
    private func button(_ action: SessionAction) -> some View {
        switch action {
        case .rename: Button { ask(.rename) } label: { Label("Rename", systemImage: "pencil") }
        case .pin: Button { run(.pin) } label: { Label("Pin", systemImage: "pin") }
        case .unpin: Button { run(.unpin) } label: { Label("Unpin", systemImage: "pin.slash") }
        case .settle: Button { run(.settle) } label: { Label("Settle", systemImage: "checkmark.circle") }
        case .reopen: Button { run(.reopen) } label: { Label("Reopen", systemImage: "arrow.uturn.backward.circle") }
        case .retry: Button { run(.retry) } label: { Label("Retry", systemImage: "arrow.clockwise") }
        case .fork: Button { fork() } label: { Label("Fork", systemImage: "arrow.triangle.branch") }
        case .restartAgent: Button { run(.restartAgent) } label: { Label("Restart agent", systemImage: "arrow.triangle.2.circlepath") }
        case .regenerateTitle: Button { run(.regenerateTitle) } label: { Label("Regenerate title", systemImage: "sparkles") }
        case .markUnread: Button { run(.markUnread) } label: { Label("Mark as unread", systemImage: "envelope.badge") }
        case .mainThreadOn: Button { run(.mainThreadOn) } label: { Label("Make main thread", systemImage: "arrow.triangle.branch") }
        case .mainThreadOff: Button { run(.mainThreadOff) } label: { Label("Stop main thread", systemImage: "arrow.triangle.branch") }
        case .archive: Button(role: .destructive) { run(.archive) } label: { Label("Archive", systemImage: "archivebox") }
        case .delete: Button(role: .destructive) { ask(.delete) } label: { Label("Delete", systemImage: "trash") }
        case .end: Button(role: .destructive) { ask(.end) } label: { Label("End session", systemImage: "xmark.circle") }
        default: EmptyView()
        }
    }

    private func run(_ action: SessionAction) {
        Haptics.tap()
        Task { await client.manage(session, action) }
    }

    private func ask(_ kind: SessionPrompt.Kind) {
        client.sessionPrompt = SessionPrompt(session: session, kind: kind)
    }

    private func fork() {
        Haptics.tap()
        Task {
            if let created = await client.manage(session, .fork)?.created { client.openSession = created }
        }
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        Haptics.success()
    }
}

/// The prompts of the session menus: a new name, Delete (with the session's own worktree where the Mac offers it), End.
struct SessionPromptHost: ViewModifier {
    @EnvironmentObject private var client: CompanionClient
    @State private var name = ""

    private func shown(_ kind: SessionPrompt.Kind) -> Binding<Bool> {
        Binding(get: { client.sessionPrompt?.kind == kind }, set: { if !$0 { client.sessionPrompt = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert("Rename", isPresented: shown(.rename), presenting: client.sessionPrompt) { prompt in
                TextField("Name", text: $name)
                Button("Save") { run(prompt.session, .rename, text: name) }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: client.sessionPrompt?.id) { _, _ in name = client.sessionPrompt?.session.title ?? "" }
            .confirmationDialog("Delete this session?", isPresented: shown(.delete), titleVisibility: .visible,
                                presenting: client.sessionPrompt) { prompt in
                Button("Delete", role: .destructive) { run(prompt.session, .delete) }
                if (prompt.session.actions ?? []).contains(SessionAction.deleteWithWorktree.rawValue) {
                    Button("Delete with worktree", role: .destructive) { run(prompt.session, .deleteWithWorktree) }
                }
            } message: { _ in
                Text("Its conversation is removed from Nook. The folder stays; a worktree with changes that were never committed stays too.")
            }
            .confirmationDialog("End this session?", isPresented: shown(.end), titleVisibility: .visible,
                                presenting: client.sessionPrompt) { prompt in
                Button("End session", role: .destructive) { run(prompt.session, .end) }
            } message: { _ in
                Text("The agent saves its conversation, so you can continue it in Nook.")
            }
    }

    private func run(_ session: SessionDigest, _ action: SessionAction, text: String? = nil) {
        Haptics.tap()
        Task { await client.manage(session, action, text: text) }
    }
}

// MARK: Composer

/// The composer's effort, mode and model in one quiet pill, as the Mac's model picker: a menu with a section each.
struct SessionControlsMenu: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    static func shows(_ session: SessionDigest, client: CompanionClient) -> Bool {
        guard client.can(CompanionFeature.agentsTab), client.allows(.operate) else { return false }
        let actions = session.actions ?? []
        return [SessionAction.setEffort, .setMode, .setModel].contains { actions.contains($0.rawValue) }
    }

    var body: some View {
        let controls = session.controls ?? SessionControls()
        let actions = session.actions ?? []
        let mode = actions.contains(SessionAction.setMode.rawValue) ? controls.mode : nil
        let efforts = actions.contains(SessionAction.setEffort.rawValue) ? controls.efforts : nil
        let models = actions.contains(SessionAction.setModel.rawValue) ? controls.models : nil
        ComposerDropdown(title: "Mode, effort and model") {
            ComposerPill(symbol: controls.mode == "plan" ? "list.bullet.clipboard" : "slider.horizontal.3", text: summary(controls))
        } content: {
            if let mode {
                DropdownHeader(title: "Mode")
                DropdownRow(symbol: "sparkles", title: String(localized: "Agent"), chosen: mode == "agent") { set(.setMode, "agent") }
                DropdownRow(symbol: "list.bullet.clipboard", title: String(localized: "Plan"), chosen: mode == "plan") { set(.setMode, "plan") }
            }
            if let efforts {
                if mode != nil { DropdownDivider() }
                DropdownHeader(title: "Effort")
                ForEach(efforts) { level in
                    DropdownRow(title: level.name, chosen: level.id == (controls.effort ?? "")) { set(.setEffort, level.id) }
                }
            }
            if let models {
                if mode != nil || efforts != nil { DropdownDivider() }
                DropdownHeader(title: "Model")
                ForEach(models) { model in
                    DropdownRow(title: model.name, chosen: model.id == (controls.model ?? "")) { set(.setModel, model.id) }
                }
            }
        }
        .accessibilityLabel("Mode, effort and model")
    }

    /// "Plan · High": what differs from the agent's defaults, else the model.
    private func summary(_ controls: SessionControls) -> String {
        var parts: [String] = []
        if controls.mode == "plan" { parts.append(String(localized: "Plan")) }
        if let effort = controls.effort, !effort.isEmpty, let name = controls.efforts?.first(where: { $0.id == effort })?.name {
            parts.append(name)
        }
        if parts.isEmpty, let model = controls.models?.first(where: { $0.id == (controls.model ?? "") })?.name { parts.append(model) }
        return parts.isEmpty ? String(localized: "Options") : parts.joined(separator: " · ")
    }

    private func set(_ action: SessionAction, _ value: String) {
        Task { await client.manage(session, action, text: value) }
    }
}

/// The messages that wait for the end of the turn, in the tray over the composer as on the Mac, each with what the Mac's
/// queue tray does with it: edit its words, send it now ahead of the rest, move it up or down, take it out. Only what
/// the Mac lists for the session is offered (`editQueued`, `sendQueuedNow`, `moveQueued`, `unqueue`).
struct QueuedMessagesStrip: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    @State private var editing: QueuedDigest?
    @State private var editText = ""

    private var offered: Set<SessionAction> {
        guard client.allows(.operate) else { return [] }
        return Set((session.actions ?? []).compactMap(SessionAction.init(rawValue:)))
    }

    var body: some View {
        if let queued = session.queued, !queued.isEmpty {
            let offered = offered
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Waiting for this turn").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                ForEach(Array(queued.enumerated()), id: \.element.id) { index, message in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Image(icon: "clock").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        Text(verbatim: message.text).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if offered.contains(.sendQueuedNow) {
                            Button { run(.sendQueuedNow, message) } label: {
                                Image(icon: "arrow.up").font(Theme.font(11, .bold)).foregroundStyle(Theme.paper)
                                    .frame(width: 36, height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(PressFade())
                            .accessibilityLabel("Send now")
                        }
                        if !offered.isDisjoint(with: [.editQueued, .moveQueued, .unqueue]) {
                            Menu {
                                if offered.contains(.editQueued) {
                                    Button {
                                        editText = message.text
                                        editing = message
                                    } label: { Label("Edit", systemImage: "pencil") }
                                }
                                if offered.contains(.sendQueuedNow) {
                                    Button { run(.sendQueuedNow, message) } label: { Label("Send now", systemImage: "arrow.up") }
                                }
                                if offered.contains(.moveQueued) {
                                    if index > 0 {
                                        Button { run(.moveQueued, message, text: String(index - 1)) } label: {
                                            Label("Move up", systemImage: "arrow.up.circle")
                                        }
                                    }
                                    if index < queued.count - 1 {
                                        Button { run(.moveQueued, message, text: String(index + 1)) } label: {
                                            Label("Move down", systemImage: "arrow.down.circle")
                                        }
                                    }
                                }
                                if offered.contains(.unqueue) {
                                    Button(role: .destructive) {
                                        Haptics.tap()
                                        Task { await client.manage(session, .unqueue, text: message.id) }
                                    } label: { Label("Remove from the queue", systemImage: "xmark") }
                                }
                            } label: {
                                Image(icon: "ellipsis").font(Theme.font(12, .bold)).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 36, height: 32).contentShape(Rectangle())
                            }
                            .accessibilityLabel("Queued message actions")
                        }
                    }
                }
            }
            .alert("Edit queued message", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("Message", text: $editText, axis: .vertical)
                Button("Save") {
                    let words = editText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let message = editing, !words.isEmpty { run(.editQueued, message, text: words) }
                    editing = nil
                }
                Button("Cancel", role: .cancel) { editing = nil }
            }
        }
    }

    private func run(_ action: SessionAction, _ message: QueuedDigest, text: String? = nil) {
        Haptics.tap()
        Task { await client.manage(session, action, text: text, items: [message.id]) }
    }
}

/// The message the Mac suggests you send next (`SessionDigest.nextPrompt`), in the tray over the composer: a tap puts it
/// in the field, as Tab takes the grey suggestion on the Mac; the cross hides it.
struct NextPromptLine: View {
    let text: String
    let take: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Button {
                Haptics.tap()
                take()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Image(icon: "sparkles").font(Theme.TextStyle.caption).foregroundStyle(Theme.iris)
                    Text(verbatim: text).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
            .accessibilityLabel("Suggested next message")
            .accessibilityValue(text)
            .accessibilityHint("Puts it in the message field")
            Button(action: dismiss) {
                Image(icon: "xmark").font(Theme.font(10, .bold)).foregroundStyle(Theme.textTertiary)
                    .frame(width: 32, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
            .accessibilityLabel("Hide the suggestion")
        }
    }
}

// MARK: Lineage

/// The sessions related to this one (`SessionDigest.lineage`), as the Mac's Lineage control: its parent, forks and
/// comparisons, the tasks it delegated and its side chats, each opening that session.
struct LineageMenu: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    var body: some View {
        if let rows = session.lineage, !rows.isEmpty {
            Menu {
                let current = rows.filter { $0.previous != true }
                let previous = rows.filter { $0.previous == true }
                ForEach(current) { row in LineageRowButton(row: row) }
                if !previous.isEmpty {
                    Section("Previous agents") {
                        ForEach(previous) { row in LineageRowButton(row: row) }
                    }
                }
            } label: {
                Label(LineageMenu.title(rows), systemImage: "arrow.triangle.branch")
            }
        }
    }

    /// "Lineage", or "Lineage · 2 running" while delegated tasks or side chats work.
    static func title(_ rows: [LineageDigest]) -> String {
        let running = rows.filter { $0.status == .working && ($0.role == .subThread || $0.role == .sideChat) }.count
        return running > 0 ? String(localized: "Lineage · \(running) running") : String(localized: "Lineage")
    }
}

private struct LineageRowButton: View {
    @EnvironmentObject private var client: CompanionClient
    let row: LineageDigest

    var body: some View {
        Button {
            Task { await client.openRelated(row.id) }
        } label: {
            Label {
                Text(verbatim: row.title)
                Text(verbatim: LineageWords.role(row.role) + " · " + LineageWords.status(row.status))
            } icon: {
                Image(systemName: LineageWords.symbol(row.role))
            }
        }
    }
}

/// Above the composer: the delegated tasks and side chats that still work or wait, as the Mac's sub-thread strip; a row
/// opens that session.
struct LineageStrip: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    private var live: [LineageDigest] {
        (session.lineage ?? []).filter { ($0.role == .subThread || $0.role == .sideChat) && $0.status.isLive }
    }

    var body: some View {
        let rows = live
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                ForEach(rows.prefix(4)) { row in
                    Button {
                        Haptics.tap()
                        Task { await client.openRelated(row.id) }
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(icon: row.status.needsYou ? "questionmark.bubble" : LineageWords.symbol(row.role))
                                .font(Theme.font(11, .semibold))
                                .foregroundStyle(row.status.needsYou ? Theme.amber : Theme.textTertiary)
                                .frame(width: 14)
                            Text(verbatim: row.title).foregroundStyle(Theme.paper.opacity(0.85)).lineLimit(1)
                            Spacer(minLength: Theme.Spacing.sm)
                            Text(verbatim: LineageWords.status(row.status))
                                .foregroundStyle(row.status.needsYou ? Theme.amber : Theme.textTertiary)
                            Image(icon: "chevron.right").font(Theme.font(9, .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        .font(Theme.TextStyle.detail)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressFade())
                    .accessibilityLabel(Text(verbatim: LineageWords.role(row.role) + ": " + row.title))
                    .accessibilityValue(Text(verbatim: LineageWords.status(row.status)))
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .roundedBackground(Theme.field, radius: Theme.Radius.control)
        }
    }
}

/// The words and symbols of a related session, as the Mac's Lineage control says them.
enum LineageWords {
    static func role(_ role: LineageDigest.Role) -> String {
        switch role {
        case .parentAgent: return String(localized: "Parent agent")
        case .parentThread: return String(localized: "Parent thread")
        case .fork: return String(localized: "Fork")
        case .comparison: return String(localized: "Same prompt, other model")
        case .subThread: return String(localized: "Sub-thread")
        case .sideChat: return String(localized: "Side chat")
        }
    }

    static func status(_ status: LineageDigest.Status) -> String {
        switch status {
        case .working: return String(localized: "Working")
        case .approval: return String(localized: "Needs approval")
        case .question: return String(localized: "Asks a question")
        case .done: return String(localized: "Done")
        case .failed: return String(localized: "Failed")
        case .stopped: return String(localized: "Stopped")
        }
    }

    static func symbol(_ role: LineageDigest.Role) -> String {
        switch role {
        case .parentAgent, .parentThread: return "arrow.turn.left.up"
        case .fork: return "arrow.triangle.branch"
        case .comparison: return "square.stack.3d.up"
        case .subThread: return "arrow.turn.down.right"
        case .sideChat: return "bubble.left.and.bubble.right"
        }
    }
}

// MARK: Questions

/// Several questions at once, or one where several options may be picked (`SessionDigest.Item.questions`): one question
/// at a time with Back and Next, options to tap (a check each where several count), your own words where the agent
/// takes them, and Send on the last one, as the Mac's question card.
struct QuestionFlow: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let item: SessionDigest.Item
    let questions: [SessionQuestion]
    @State private var step = 0
    @State private var picked: [String: [String]] = [:]
    @State private var own: [String: String] = [:]

    private var question: SessionQuestion { questions[min(step, questions.count - 1)] }
    private var answers: [String: [String]] {
        var all: [String: [String]] = [:]
        for question in questions {
            let words = (own[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            all[question.id] = (picked[question.id] ?? []) + (words.isEmpty || !question.allowsOther ? [] : [words])
        }
        return all
    }
    private var answered: Bool { !(answers[question.id] ?? []).isEmpty }
    private var complete: Bool { SessionAnswers.validated(answers, for: questions) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if questions.count > 1 {
                Text("Question \(step + 1) of \(questions.count)").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
            if !question.header.isEmpty {
                Text(verbatim: question.header).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
            }
            Text(verbatim: question.question).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper)
            if question.multiSelect {
                Text("Pick one or more").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(question.options.enumerated()), id: \.offset) { number, option in
                    QuestionChoiceRow(title: option, number: number, picked: (picked[question.id] ?? []).contains(option),
                                      multiSelect: question.multiSelect) {
                        Haptics.tap()
                        let next = SessionAnswers.toggle(option, in: picked[question.id] ?? [], multiSelect: question.multiSelect)
                        picked[question.id] = next
                        if !question.multiSelect { own[question.id] = "" }
                    }
                    if let previews = question.previews, previews.indices.contains(number), !previews[number].isEmpty {
                        QuestionOptionPreview(text: previews[number], indent: Theme.Spacing.lg, lineLimit: 10)
                    }
                }
            }
            if question.allowsOther {
                TextField("Your own answer", text: Binding(get: { own[question.id] ?? "" }, set: { words in
                    own[question.id] = words
                    if !question.multiSelect, !words.isEmpty { picked[question.id] = [] }
                }), axis: .vertical)
                .font(Theme.TextStyle.body)
                .padding(Theme.Spacing.md)
                .roundedBackground(Theme.field, radius: Theme.Radius.control)
            }
            HStack(spacing: Theme.Spacing.md) {
                if step > 0 {
                    NookGhostButton(title: String(localized: "Back")) { withAnimation(Theme.reveal) { step -= 1 } }
                }
                Spacer(minLength: 0)
                if step < questions.count - 1 {
                    NookPrimaryButton(title: String(localized: "Next")) { withAnimation(Theme.reveal) { step += 1 } }
                        .disabled(!answered)
                } else {
                    NookPrimaryButton(title: String(localized: "Send answers")) {
                        Haptics.success()
                        Task { await client.answer(session, item: item, text: "", answers: answers) }
                    }
                    .disabled(!complete)
                }
            }
        }
    }
}

/// One option of a question: its number, the answer, and a check while it is picked (a square where several count).
private struct QuestionChoiceRow: View {
    let title: String
    let number: Int
    let picked: Bool
    let multiSelect: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(icon: picked ? (multiSelect ? "checkmark.square.fill" : "checkmark.circle.fill") : (multiSelect ? "square" : "circle"))
                    .foregroundStyle(picked ? Theme.iris : Theme.textTertiary)
                Text(title)
                    .font(Theme.textFont(13, .semibold))
                    .foregroundStyle(Theme.paper)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Theme.Spacing.xs)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md + 1)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .cardBackground(Theme.field, stroke: picked ? Theme.iris.opacity(0.5) : Theme.paper.opacity(0.08), radius: Theme.Radius.card)
            .roundedHitShape(Theme.Radius.card)
        }
        .buttonStyle(PressFade())
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

// MARK: New session

// MARK: How a session ended

/// The card at the end of a session's conversation when it needs a next step, as the Mac's timeline ends: a usage limit
/// with when it resets and *Resume when it resets*, a failed turn with *Retry*, a settled session with *Reopen*. Only
/// what the Mac lists for the session (`SessionDigest.actions`) is offered; the words stay without buttons otherwise.
struct SessionEndCard: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    private enum Ending { case limited, failed, settled }

    private var ending: Ending? {
        switch session.attention {
        case "limited": return .limited
        case "failed": return .failed
        default: return session.settled == true ? .settled : nil
        }
    }

    private var actions: [SessionAction] {
        guard client.can(CompanionFeature.manage), client.allows(.operate) else { return [] }
        return (session.actions ?? []).compactMap(SessionAction.init(rawValue:))
    }

    var body: some View {
        if let ending {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Label {
                    Text(title(ending)).font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                } icon: {
                    Image(icon: symbol(ending)).foregroundStyle(tint(ending))
                }
                if let detail = detail(ending) {
                    Text(detail).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let buttons = buttons(ending)
                if !buttons.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(buttons, id: \.action) { button in
                            Button {
                                Haptics.tap()
                                Task { await client.manage(session, button.action) }
                            } label: {
                                Label(button.title, systemImage: button.symbol)
                                    .font(Theme.TextStyle.label)
                                    .foregroundStyle(button.primary ? Theme.onIris : Theme.paper)
                                    .padding(.horizontal, Theme.Spacing.lg)
                                    .frame(minHeight: 36)
                                    .background(Capsule().fill(button.primary ? Theme.iris : Theme.smoke))
                            }
                            .buttonStyle(PressFade())
                            .disabled(client.isOffline)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(tint: ending == .settled ? nil : tint(ending))
            .padding(.top, Theme.Spacing.sm)
        }
    }

    private struct EndButton {
        let action: SessionAction
        let title: String
        let symbol: String
        var primary = false
    }

    private func buttons(_ ending: Ending) -> [EndButton] {
        var all: [EndButton] = []
        switch ending {
        case .limited:
            if actions.contains(.snoozeLimitReset), session.limitResetsAt != nil {
                all.append(EndButton(action: .snoozeLimitReset, title: String(localized: "Resume when it resets"),
                                     symbol: "clock.arrow.circlepath", primary: true))
            }
            if actions.contains(.retry) {
                all.append(EndButton(action: .retry, title: String(localized: "Retry"), symbol: "arrow.clockwise",
                                     primary: all.isEmpty))
            }
        case .failed:
            if actions.contains(.retry) {
                all.append(EndButton(action: .retry, title: String(localized: "Retry"), symbol: "arrow.clockwise", primary: true))
            }
        case .settled:
            if actions.contains(.reopen) {
                all.append(EndButton(action: .reopen, title: String(localized: "Reopen"), symbol: "arrow.uturn.backward"))
            }
        }
        return all
    }

    private func title(_ ending: Ending) -> LocalizedStringKey {
        switch ending {
        case .limited: return "Usage limit reached"
        case .failed: return "The last turn failed"
        case .settled: return "This session is settled"
        }
    }

    private func detail(_ ending: Ending) -> String? {
        switch ending {
        case .limited:
            guard let resets = session.limitResetsAt else { return nil }
            let date = Date(timeIntervalSince1970: resets)
            guard date > Date() else { return String(localized: "The limit has reset: the agent can go on.") }
            let time = date.formatted(Calendar.current.isDateInToday(date) ? .dateTime.hour().minute()
                                                                            : .dateTime.weekday(.wide).hour().minute())
            return String(localized: "Resets at \(time).")
        case .failed:
            return nil
        case .settled:
            return String(localized: "Done for now: it waits in Settled until you reopen it or write to it.")
        }
    }

    private func symbol(_ ending: Ending) -> String {
        switch ending {
        case .limited: return "hourglass"
        case .failed: return "exclamationmark.triangle.fill"
        case .settled: return "checkmark.circle"
        }
    }

    private func tint(_ ending: Ending) -> Color {
        switch ending {
        case .limited: return Theme.amber
        case .failed: return Theme.coral
        case .settled: return Theme.mint
        }
    }
}

// MARK: Demo

extension CompanionClient {
    /// The demo's sessions with the Agents tab's menus, shelves, composer choices, queue and a multi-question ask.
    static func demoAgentsTab(_ sessions: [SessionDigest], now: Double) -> [SessionDigest] {
        sessions.map { session in
            var session = session
            session.path = "/Users/you/code/" + session.folder
            var actions = ["rename", "markUnread", "regenerateTitle"]
            switch session.id {
            case "s2":
                session.pinned = true
                actions += ["unpin", "setEffort", "setMode", "setModel", "unqueue", "editQueued", "moveQueued", "sendQueuedNow"]
                session.controls = SessionControls(effort: "high", efforts: [.init(id: "", name: "Default"), .init(id: "medium", name: "Medium"),
                                                                             .init(id: "high", name: "High")],
                                                   mode: "agent", model: "gpt-5", models: [.init(id: "", name: "Default"), .init(id: "gpt-5", name: "GPT-5")])
                session.queued = [QueuedDigest(id: "q1", text: "Then add a test for the wake path."),
                                  QueuedDigest(id: "q2", text: "And update the changelog.")]
                session.canSteer = true
                // Its lineage: a sub-thread at work, one that waits on you, one that ended, a side chat.
                session.lineage = [
                    LineageDigest(id: "s1", title: "Add the usage page to Settings", role: .parentThread, status: .approval),
                    LineageDigest(id: "t1", title: "Write the wake-path test", role: .subThread, status: .working),
                    LineageDigest(id: "t2", title: "Check the relay logs", role: .subThread, status: .question),
                    LineageDigest(id: "t3", title: "Read the NWPathMonitor docs", role: .subThread, status: .done, previous: true),
                ]
            case "s3":
                actions += ["pin", "settle", "fork", "restartAgent", "delete", "deleteWithWorktree", "snoozeHour", "snoozeEvening", "snoozeTomorrow"]
                var item = SessionDigest.Item(id: "qa", kind: .question, title: "Which languages first?", detail: "", canAllow: false, options: [])
                item.questions = [
                    SessionQuestion(id: "q1", header: "Languages", question: "Which languages first?", options: ["Dutch", "German", "French"],
                                    multiSelect: true, allowsOther: true),
                    SessionQuestion(id: "q2", header: "Tone", question: "Formal or casual?", options: ["Formal", "Casual"],
                                    multiSelect: false, allowsOther: false),
                ]
                session.items = [item]
                session.attention = "input"
            case "s4":
                session.snoozedUntil = now + 3600
                actions += ["pin", "settle", "unsnooze", "fork", "delete"]
            case "s5":
                session.settled = true
                // A finished turn: the suggested next message, and what Nook could do next.
                session.nextPrompt = "Now open a pull request for this."
                session.suggestion = ActionSuggestionDigest(
                    conversation: "agent:s5", steps: [.init(text: "Remind you tomorrow at 9:00 to test on a real Mac", symbol: "bell")],
                    reason: "You said you would check it on your Mac.", state: .waiting)
                actions += ["pin", "reopen", "retry", "fork", "delete", "archive"]
            default:
                actions += ["pin", "settle", "fork", "snoozeHour"]
                if var item = session.items.first, item.kind == .approval {
                    item.canAlways = true
                    session.items = [item]
                }
            }
            session.actions = actions
            return session
        }
    }
}
