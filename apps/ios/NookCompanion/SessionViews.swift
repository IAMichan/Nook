import SwiftUI

// MARK: One session

/// A session as a conversation: what you asked, what the agent answered and did, what waits on you, and a field to reply.
struct SessionDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var message = ""
    @State private var confirmStop = false

    private var session: SessionDigest? { client.sessions.first { $0.id == sessionID } }
    private var entries: [TimelineEntry] { client.timelines[sessionID] ?? [] }

    var body: some View {
        if let session {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        header(session)
                        if client.can(CompanionFeature.timeline) {
                            ForEach(entries) { TimelineRow(entry: $0) }
                        } else if !session.excerpt.isEmpty {
                            Text("Latest reply").font(.caption).foregroundStyle(.secondary)
                            MessageBubble(text: session.excerpt, mine: false)
                        }
                        ForEach(session.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(Self.sectionTitle(for: item)).font(.caption.weight(.semibold)).foregroundStyle(Palette.amber)
                                ItemView(session: session, item: item)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: entries.last?.id) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onChange(of: session.items.count) { _, _ in withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom) {
                ComposerBar(placeholder: "Message to the agent", text: $message) { text in
                    Task { await client.send(session, text: text) }
                }
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if session.attention == "working" || session.attention == "approval" || session.attention == "input" {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Stop", role: .destructive) { confirmStop = true }
                    }
                }
            }
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the session", role: .destructive) { Task { await client.stop(session) } }
            }
            // While the session is on screen its conversation stays current; leaving the screen ends the loop.
            .task {
                while !Task.isCancelled {
                    await client.loadTimeline(sessionID)
                    let working = client.sessions.first { $0.id == sessionID }?.attention == "working"
                    try? await Task.sleep(for: .seconds(working ? 2 : 5))
                }
            }
        } else {
            Text("This session is gone.").foregroundStyle(.secondary)
        }
    }

    private static let bottom = "bottom"

    private func header(_ session: SessionDigest) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(Palette.word(session.attention), systemImage: "circle.fill")
                .font(.subheadline.weight(.medium)).foregroundStyle(Palette.color(session.attention))
            Text("\(session.agent) · \(session.folder)\(session.branch.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    /// The heading above an item: typed, so both texts go through the String Catalog.
    private static func sectionTitle(for item: SessionDigest.Item) -> LocalizedStringKey {
        item.kind == .approval ? "Approval" : "Question"
    }
}

/// One step of a session: messages as bubbles, tools and file changes as quiet lines.
struct TimelineRow: View {
    let entry: TimelineEntry

    var body: some View {
        switch entry.kind {
        case .user:
            MessageBubble(text: entry.text, mine: true)
        case .assistant:
            MessageBubble(text: entry.text, mine: false)
        case .tool:
            step(symbol: entry.failed ? "xmark.octagon" : "wrench.and.screwdriver", title: entry.detail, text: entry.text)
        case .change:
            step(symbol: "doc.badge.ellipsis", title: entry.detail, text: entry.text)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(Palette.coral).textSelection(.enabled)
        case .notice:
            Text(entry.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private func step(symbol: String, title: String?, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(entry.failed ? Palette.coral : .secondary)
            if let title, !title.isEmpty { Text(title).fontWeight(.medium) }
            Text(text).foregroundStyle(.secondary).lineLimit(2)
        }
        .font(.caption.monospaced())
        .padding(.horizontal, 4)
    }
}

// MARK: Starting a session

/// A new session on the Mac: the task, the agent and the folder. Account, model and permissions come from the Mac's own
/// defaults for that agent, and "allow everything" is never used for a session started here.
struct NewSessionView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    let started: (String) -> Void

    @State private var task = ""
    @State private var title = ""
    @State private var agent = ""
    @State private var project = ""
    @State private var plan = false
    @State private var worktree = false
    @State private var loaded = false
    @State private var prepared = false
    @State private var starting = false
    /// Why the last start did not work; shown in the sheet, where the app's alert cannot appear.
    @State private var failure: String?
    @FocusState private var focused: Bool

    private var options: LaunchOptions? { client.launchOptions }
    private var chosenAgent: LaunchOptions.Agent? { options?.agents.first { $0.id == agent } }
    private var chosenProject: LaunchOptions.Project? { options?.projects.first { $0.path == project } }
    private var canStart: Bool {
        !starting && chosenAgent != nil && chosenProject != nil && !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let options {
                    form(options)
                } else if loaded {
                    ContentUnavailableView("Your Mac does not answer.", systemImage: "wifi.slash")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if starting {
                        ProgressView()
                    } else {
                        Button("Start") { start() }.disabled(!canStart)
                    }
                }
            }
            .onAppear(perform: prepare)
            .task {
                await client.loadLaunchOptions()
                loaded = true
                prepare()
            }
        }
    }

    @ViewBuilder
    private func form(_ options: LaunchOptions) -> some View {
        if options.agents.isEmpty {
            ContentUnavailableView("No agent is ready on your Mac.", systemImage: "person.crop.circle.badge.questionmark",
                                   description: Text("Connect one in Nook › Settings › Agents."))
        } else if options.projects.isEmpty {
            ContentUnavailableView("No folders yet.", systemImage: "folder",
                                   description: Text("Start a session on your Mac once: its folder then shows up here."))
        } else {
            Form {
                Section("Task") {
                    TextField("What should the agent do?", text: $task, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                }
                Section {
                    Picker("Agent", selection: $agent) {
                        ForEach(options.agents) { Text($0.name).tag($0.id) }
                    }
                    Picker("Folder", selection: $project) {
                        ForEach(options.projects) { Text($0.name).tag($0.path) }
                    }
                    if chosenAgent?.canPlan == true {
                        Toggle("Plan first, without changing anything", isOn: $plan)
                    }
                    if chosenProject?.canWorktree == true {
                        Toggle("On its own branch (worktree)", isOn: $worktree)
                    }
                    TextField("Title (optional)", text: $title)
                } footer: {
                    Text("Nook uses your account, model and permissions for this agent. Anything risky still waits for your approval.")
                }
                if let failure {
                    Section { Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.coral) }
                }
            }
        }
    }

    /// Your defaults from the Mac, once.
    private func prepare() {
        guard !prepared, let options else { return }
        prepared = true
        agent = options.defaultAgent ?? options.agents.first?.id ?? ""
        project = options.defaultProject ?? options.projects.first?.path ?? ""
        plan = options.defaultPlan
        worktree = options.defaultWorktree
        focused = true
    }

    private func start() {
        guard canStart else { return }
        starting = true
        failure = nil
        let launch = LaunchRequest(agent: agent, project: project, task: task, title: title.isEmpty ? nil : title,
                                   plan: plan && chosenAgent?.canPlan == true,
                                   worktree: worktree && chosenProject?.canWorktree == true)
        Task {
            let id = await client.start(launch)
            starting = false
            guard let id else {
                failure = client.notice ?? String(localized: "Your Mac refused this.")
                client.notice = nil
                return
            }
            dismiss()
            started(id)
        }
    }
}

struct ItemView: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let item: SessionDigest.Item
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.body)
            if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary) }
            switch item.kind {
            case .approval:
                HStack {
                    Button("Deny", role: .destructive) { Task { await client.decide(session, item: item, allow: false) } }
                        .buttonStyle(.bordered)
                    if item.canAllow {
                        Button("Allow") { Task { await client.decide(session, item: item, allow: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if !item.canAllow {
                    Text("This is risky or unknown: it can only be allowed on your Mac.").font(.caption).foregroundStyle(Palette.amber)
                }
            case .question:
                if item.canAllow {
                    ForEach(item.options, id: \.self) { option in
                        Button(option) { Task { await client.answer(session, item: item, text: option) } }.buttonStyle(.bordered)
                    }
                    HStack {
                        TextField("Your own answer", text: $text)
                        Button("Send") {
                            let answer = text
                            text = ""
                            Task { await client.answer(session, item: item, text: answer) }
                        }
                        .disabled(text.isEmpty)
                    }
                } else {
                    Text("Several questions at once: answer them on your Mac.").font(.caption).foregroundStyle(Palette.amber)
                }
            }
        }
    }
}
