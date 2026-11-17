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

    /// "Copy" with the session's folder, branch and id, as on the Mac.
    private var copyMenu: some View {
        Menu {
            Button("Path") { copy(session.path ?? session.folder) }
            if let branch = session.branch, !branch.isEmpty { Button("Branch") { copy(branch) } }
            Button("Session ID") { copy(session.id) }
        } label: { Label("Copy", systemImage: "doc.on.doc") }
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
        Menu {
            if actions.contains(SessionAction.setMode.rawValue), let mode = controls.mode {
                Section("Mode") {
                    choice(String(localized: "Agent"), on: mode == "agent") { set(.setMode, "agent") }
                    choice(String(localized: "Plan"), on: mode == "plan") { set(.setMode, "plan") }
                }
            }
            if actions.contains(SessionAction.setEffort.rawValue), let efforts = controls.efforts {
                Section("Effort") {
                    ForEach(efforts) { level in choice(level.name, on: level.id == (controls.effort ?? "")) { set(.setEffort, level.id) } }
                }
            }
            if actions.contains(SessionAction.setModel.rawValue), let models = controls.models {
                Section("Model") {
                    ForEach(models) { model in choice(model.name, on: model.id == (controls.model ?? "")) { set(.setModel, model.id) } }
                }
            }
        } label: {
            ComposerPill(symbol: controls.mode == "plan" ? "list.bullet.clipboard" : "slider.horizontal.3", text: summary(controls))
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

    private func choice(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if on { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func set(_ action: SessionAction, _ value: String) {
        Haptics.tap()
        Task { await client.manage(session, action, text: value) }
    }
}

/// The messages that wait for the end of the turn, above the composer as on the Mac, each with a way to take it out.
struct QueuedMessagesStrip: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    var body: some View {
        if let queued = session.queued, !queued.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Waiting for this turn").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Theme.Spacing.xs)
                ForEach(queued) { message in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Image(icon: "clock").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        Text(verbatim: message.text).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                            .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if (session.actions ?? []).contains(SessionAction.unqueue.rawValue), client.allows(.operate) {
                            Button {
                                Haptics.tap()
                                Task { await client.manage(session, .unqueue, text: message.id) }
                            } label: {
                                Image(icon: "xmark").font(Theme.font(10, .bold)).foregroundStyle(Theme.textSecondary)
                                    .frame(width: 44, height: 32).contentShape(Rectangle())
                            }
                            .buttonStyle(PressFade())
                            .accessibilityLabel("Remove from the queue")
                        }
                    }
                    .padding(.leading, Theme.Spacing.md)
                    .roundedBackground(Theme.field, radius: Theme.Radius.control)
                }
            }
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

/// A file for the new session, from Files (`CompanionFeature.attachments`), up to what one request carries.
struct AttachFileButton: View {
    @Binding var files: [CompanionFile]
    var images: [CompanionImage] = []
    @State private var importing = false
    @State private var tooLarge = false

    var body: some View {
        Button { importing = true } label: {
            ComposerPill(symbol: "paperclip", text: String(localized: "File"), showsChevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach a file")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count <= CompanionFile.maxBytes else {
                tooLarge = true
                Haptics.warning()
                return
            }
            let next = [CompanionFile(name: url.lastPathComponent, bytes: data)]
            guard CompanionFile.fits(images: images, files: next) else {
                tooLarge = true
                return
            }
            withAnimation(Theme.reveal) { files = next }
        }
        .alert("Too large to send from your phone", isPresented: $tooLarge) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A file from the phone can be at most 150 KB.")
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
                actions += ["unpin", "setEffort", "setMode", "setModel", "unqueue"]
                session.controls = SessionControls(effort: "high", efforts: [.init(id: "", name: "Default"), .init(id: "medium", name: "Medium"),
                                                                             .init(id: "high", name: "High")],
                                                   mode: "agent", model: "gpt-5", models: [.init(id: "", name: "Default"), .init(id: "gpt-5", name: "GPT-5")])
                session.queued = [QueuedDigest(id: "q1", text: "Then add a test for the wake path.")]
                session.canSteer = true
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
