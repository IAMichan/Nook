import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The share sheet's "Nook" (docs/COMPANION.md, "Sharing to Nook"): text, links, pictures and a file from any app, to a
/// new session, a session that runs, or a question to Nook, on the Mac the app last used. The extension holds no pairing
/// key and talks to no Mac: it leaves the share in the app group (`ShareQueue`), and the app puts it in that Mac's outbox
/// the next time it opens, where it waits for the Mac like anything written in the app.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model).preferredColorScheme(.dark))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

@MainActor
final class ShareModel: ObservableObject {
    enum Choice: String, CaseIterable, Identifiable {
        case newSession, session, nook
        var id: String { rawValue }
    }

    @Published var note = ""
    @Published var shared: [String] = []
    @Published var images: [CompanionImage] = []
    @Published var files: [CompanionFile] = []
    @Published var problem: String?
    @Published var loading = true
    @Published var choice: Choice = .newSession
    @Published var agent = ""
    @Published var project = ""
    @Published var worktree = false
    @Published var session = ""
    let targets: ShareTargets?
    private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
        targets = AppGroup.read(AppGroup.shareTargets, as: ShareTargets.self)
        if let launch = targets?.launch {
            agent = launch.defaultAgent ?? launch.agents.first?.id ?? ""
            project = launch.defaultProject ?? launch.projects.first?.path ?? ""
            worktree = launch.defaultWorktree
        }
        session = targets?.sessions.first?.id ?? ""
        choice = choices.first ?? .newSession
    }

    /// What the Mac lets this phone do with a share.
    var choices: [Choice] {
        guard let targets else { return [] }
        var list: [Choice] = []
        if targets.canStart, let launch = targets.launch, !launch.agents.isEmpty, !launch.projects.isEmpty { list.append(.newSession) }
        if targets.canSend, !targets.sessions.isEmpty { list.append(.session) }
        if targets.canAsk { list.append(.nook) }
        return list
    }

    func load() async {
        defer { loading = false }
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                guard images.count < CompanionImage.maxCount else { continue }
                if let image = await loadImage(provider), let encoded = CompanionImageEncoder.encode(image) {
                    images.append(encoded)
                } else {
                    problem = String(localized: "A picture could not be read.")
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                await loadFile(provider)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL { await loadFile(provider) } else { shared.append(url.absoluteString) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    shared.append(String(text.prefix(6_000)))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier) {
                await loadFile(provider)
            }
        }
    }

    private func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        if let image = item as? UIImage { return image }
        if let url = item as? URL, let data = try? Data(contentsOf: url) { return UIImage(data: data) }
        if let data = item as? Data { return UIImage(data: data) }
        return nil
    }

    private func loadFile(_ provider: NSItemProvider) async {
        guard files.count < CompanionFile.maxCount else {
            problem = String(localized: "Only one file goes with a message.")
            return
        }
        let type = provider.registeredTypeIdentifiers.first ?? UTType.data.identifier
        let item = try? await provider.loadItem(forTypeIdentifier: type)
        var data: Data?
        var name = provider.suggestedName ?? "file"
        if let url = item as? URL {
            name = url.lastPathComponent
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= CompanionFile.maxBytes else {
                problem = String(localized: "\(name) is too big to send through your iPhone (at most 150 KB). Share it on your Mac instead.")
                return
            }
            data = try? Data(contentsOf: url)
        } else if let bytes = item as? Data {
            data = bytes
        }
        guard let data, !data.isEmpty else {
            problem = String(localized: "The file could not be read.")
            return
        }
        guard data.count <= CompanionFile.maxBytes else {
            problem = String(localized: "\(name) is too big to send through your iPhone (at most 150 KB). Share it on your Mac instead.")
            return
        }
        files.append(CompanionFile(name: CompanionFile.safeName(name) ?? "file", bytes: data))
    }

    var target: SharedItem.Target? {
        switch choice {
        case .newSession: return agent.isEmpty || project.isEmpty ? nil : .newSession(agent: agent, project: project, worktree: worktree)
        case .session: return session.isEmpty ? nil : .session(session)
        case .nook: return .nookChat
        }
    }

    /// The share as it would go, or nil.
    var item: SharedItem? {
        guard let targets, let target else { return nil }
        let attachFiles = targets.canAttach ? files : []
        let attachImages = targets.canImages ? images : []
        return SharedItem(mac: targets.mac, target: target, text: SharedItem.words(note: note, shared: shared),
                          images: choice == .nook ? [] : attachImages, files: choice == .nook ? [] : attachFiles)
    }

    /// Why Send is off, in words; nil when it can go.
    var blocker: String? {
        guard let item else { return String(localized: "Choose where it goes.") }
        if choice == .nook, !images.isEmpty || !files.isEmpty {
            return String(localized: "Nook's chat takes words only: pictures and files go to a session.")
        }
        if let targets, !targets.canAttach, !files.isEmpty { return String(localized: "Nook on your Mac is too old to take files.") }
        switch item.problem {
        case .needsWords?: return String(localized: "Write what the agent should do.")
        case .tooBig?: return String(localized: "Together this is too big for one message.")
        case .nookTakesNoFiles?: return String(localized: "Nook's chat takes words only: pictures and files go to a session.")
        case nil: return nil
        }
    }

    func send() {
        guard blocker == nil, let item else { return }
        var added = false
        AppGroup.update(AppGroup.shareQueue, empty: ShareQueue()) { queue in added = queue.add(item) }
        if added {
            context?.completeRequest(returningItems: nil)
        } else {
            problem = String(localized: "Too much waits for Nook Companion already. Open it to send what waits.")
        }
    }

    func cancel() {
        context?.cancelRequest(withError: NSError(domain: "nl.imdigital.nook.share", code: NSUserCancelledError))
    }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                if model.targets == nil {
                    Section {
                        Text("Open Nook Companion and pair it with Nook on your Mac first.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    Section {
                        TextField("Add a note", text: $model.note, axis: .vertical).lineLimit(2...6)
                        ForEach(model.shared, id: \.self) { text in
                            Text(text).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(3)
                        }
                        if !model.images.isEmpty { ImageTray(images: $model.images) }
                        ForEach(model.files, id: \.name) { file in
                            Label(file.name, systemImage: "doc").foregroundStyle(Theme.textSecondary)
                        }
                        if model.loading { ProgressView() }
                    }
                    if model.choices.count > 1 {
                        Section {
                            Picker("Send to", selection: $model.choice) {
                                ForEach(model.choices) { choice in Text(title(choice)).tag(choice) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    targetSection
                    if let problem = model.problem ?? (model.loading ? nil : model.blocker) {
                        Section { Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(Theme.amber) }
                    }
                    if let targets = model.targets {
                        Section {
                            Text("Goes to \(targets.macName) the next time Nook Companion opens, and waits there while your Mac is away.")
                                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle("Nook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { model.send() }.disabled(model.loading || model.blocker != nil || model.targets == nil)
                }
            }
        }
        .tint(Theme.iris)
    }

    @ViewBuilder
    private var targetSection: some View {
        switch model.choice {
        case .newSession:
            if let launch = model.targets?.launch {
                Section {
                    Picker("Agent", selection: $model.agent) {
                        ForEach(launch.agents) { agent in Text(agent.name).tag(agent.id) }
                    }
                    Picker("Folder", selection: $model.project) {
                        ForEach(launch.projects) { project in Text(project.name).tag(project.path) }
                    }
                    if launch.projects.first(where: { $0.path == model.project })?.canWorktree == true {
                        Toggle("On its own branch", isOn: $model.worktree)
                    }
                }
            }
        case .session:
            Section {
                Picker("Session", selection: $model.session) {
                    ForEach(model.targets?.sessions ?? []) { session in
                        Text("\(session.title) · \(session.agent)").tag(session.id)
                    }
                }
            }
        case .nook:
            EmptyView()
        }
    }

    private func title(_ choice: ShareModel.Choice) -> String {
        switch choice {
        case .newSession: return String(localized: "New session")
        case .session: return String(localized: "Session")
        case .nook: return String(localized: "Ask Nook")
        }
    }
}
