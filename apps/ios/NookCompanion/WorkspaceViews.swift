import SwiftUI

/// The session's menu for its files and terminals, where the Mac offers them. On the phone each opens as a pushed
/// screen; on an iPad with room (a regular width) in an inspector beside the conversation, so you read the files while
/// you follow and answer the agent.
struct SessionWorkspaceMenu: ViewModifier {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.horizontalSizeClass) private var sizeClass
    let sessionID: String
    @State private var showsFiles = false
    @State private var showsTerminals = false
    @State private var showsPulls = false
    /// The iPad's inspector: open, and which pane it shows.
    @State private var inspecting = false
    @State private var pane = WorkspacePane.files
    /// The split view's list, folded away while the inspector needs its room (an iPad in portrait).
    @Environment(\.sidebarRoom) private var sidebarRoom
    @State private var width: CGFloat = 0
    @State private var foldedSidebar = false

    private var panes: [WorkspacePane] {
        WorkspacePane.allCases.filter { pane in
            switch pane {
            case .files, .terminals: return client.can(CompanionFeature.workspace)
            case .pulls: return client.can(CompanionFeature.pullRequests)
            }
        }
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if !panes.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            ForEach(panes, id: \.self) { pane in
                                Button { show(pane) } label: { Label(pane.title, systemImage: pane.symbol) }
                            }
                        } label: {
                            Image(icon: "ellipsis.circle")
                        }
                        .accessibilityLabel("Files, terminals and pull requests")
                    }
                }
            }
            .navigationDestination(isPresented: $showsFiles) { SessionFilesView(sessionID: sessionID) }
            .navigationDestination(isPresented: $showsTerminals) { SessionTerminalsView(sessionID: sessionID) }
            .navigationDestination(isPresented: $showsPulls) { PullRequestListView(session: sessionID) }
            .inspector(isPresented: $inspecting) {
                WorkspaceInspector(sessionID: sessionID, panes: panes, pane: $pane)
                    .inspectorColumnWidth(min: CompanionLayout.inspectorMin, ideal: CompanionLayout.inspectorIdeal,
                                          max: CompanionLayout.inspectorMax)
            }
            // The window got narrow (Slide Over, a small Split View): the inspector would turn into a sheet over the
            // conversation, so it closes; the menu pushes from then on.
            .onChange(of: sizeClass) { _, size in
                if size != .regular { inspecting = false }
            }
            // Beside the list and the inspector the conversation would get too narrow to read: the list folds away
            // while the inspector is open, and comes back when it closes.
            .background { GeometryReader { proxy in Color.clear.onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { _, new in width = new } } }
            .onChange(of: inspecting) { _, open in
                if open, width - CompanionLayout.inspectorIdeal < CompanionLayout.conversationMin, let sidebarRoom {
                    foldedSidebar = true
                    sidebarRoom.fold()
                } else if !open, foldedSidebar {
                    foldedSidebar = false
                    sidebarRoom?.unfold()
                }
            }
            #if DEBUG
            // `-NookDemoShow files` with `-NookDemo`: the session with its files open.
            .task {
                if UserDefaults.standard.string(forKey: "NookDemoShow") == "files", !panes.isEmpty { show(.files) }
            }
            #endif
    }

    private func show(_ pane: WorkspacePane) {
        if sizeClass == .regular {
            self.pane = pane
            inspecting = true
            return
        }
        switch pane {
        case .files: showsFiles = true
        case .terminals: showsTerminals = true
        case .pulls: showsPulls = true
        }
    }
}

/// What a session's inspector shows: its files, its terminals or its pull requests.
enum WorkspacePane: CaseIterable {
    case files, terminals, pulls

    var title: LocalizedStringKey {
        switch self {
        case .files: return "Files"
        case .terminals: return "Terminals"
        case .pulls: return "Pull requests"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "folder"
        case .terminals: return "terminal"
        case .pulls: return "arrow.triangle.pull"
        }
    }
}

/// The iPad's inspector beside a session: the phone's Files, Terminals and Pull requests screens, one at a time, picked
/// at its top. Each has a stack of its own, so a folder or a pull request opens inside the inspector.
private struct WorkspaceInspector: View {
    let sessionID: String
    let panes: [WorkspacePane]
    @Binding var pane: WorkspacePane

    var body: some View {
        NavigationStack {
            Group {
                switch pane {
                case .files: SessionFilesView(sessionID: sessionID)
                case .terminals: SessionTerminalsView(sessionID: sessionID)
                case .pulls: PullRequestListView(session: sessionID)
                }
            }
            .id(pane)
            .safeAreaInset(edge: .top, spacing: 0) {
                if panes.count > 1 {
                    Picker("Show", selection: $pane) {
                        ForEach(panes, id: \.self) { pane in Label(pane.title, systemImage: pane.symbol).tag(pane) }
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.titleOnly)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.canvas)
                }
            }
        }
    }
}

/// A session's folder on the phone, to read. The Mac leaves out secrets by their name.
struct SessionFilesView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    var path = ""
    /// The file's size as its folder listed it; nil for a folder or when not known.
    var size: Int? = nil
    @State private var digest: FolderDigest?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let digest {
                    if digest.binary == true {
                        // Pictures, PDFs and films open with Quick Look where the Mac sends files
                        // (`CompanionFeature.filePreview`).
                        if client.can(CompanionFeature.filePreview) {
                            FilePreviewPanel(sessionID: sessionID, path: path, size: size)
                        } else {
                            WSEmptyState(symbol: "doc", title: String(localized: "No text"),
                                         message: String(localized: "This file cannot be shown on the phone."))
                        }
                    } else if let text = digest.text {
                        Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.paper).textSelection(.enabled)
                        if digest.truncated == true {
                            Text("Only the start of this file is shown.").font(Theme.TextStyle.label).foregroundStyle(Theme.textTertiary)
                        }
                    } else {
                        if digest.truncated == true {
                            Text("Only the first entries of this folder are shown.").font(Theme.TextStyle.label).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(digest.entries ?? []) { entry in
                            NavigationLink {
                                SessionFilesView(sessionID: sessionID, path: path.isEmpty ? entry.name : path + "/" + entry.name,
                                                 size: entry.size)
                            } label: {
                                Label(entry.name, systemImage: entry.isFolder ? "folder" : Self.symbol(entry.name))
                                    .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, Theme.Spacing.xs)
                            }
                        }
                    }
                } else if failed {
                    WSEmptyState(symbol: "lock", title: String(localized: "Not available"),
                                 message: String(localized: "The Mac does not share this."))
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxxl)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .navigationTitle(path.isEmpty ? String(localized: "Files") : (path.split(separator: "/").last.map(String.init) ?? path))
        .screen()
        .task {
            digest = await client.loadFiles(sessionID, path: path)
            failed = digest == nil
        }
    }

    /// A file's symbol by its kind, so a picture or a PDF reads as one in the list.
    static func symbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav", "aiff": return "waveform"
        default: return "doc.text"
        }
    }
}

/// The terminals of a session's folder, to follow from the phone.
struct SessionTerminalsView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var terminals: [TerminalDigest]?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let terminals {
                    if terminals.isEmpty {
                        WSEmptyState(symbol: "terminal", title: String(localized: "No terminals"),
                                     message: String(localized: "This session has no terminal open on the Mac."))
                    }
                    ForEach(terminals) { terminal in
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Label(terminal.title, systemImage: terminal.running ? "play.circle" : "stop.circle")
                                .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                            Text(terminal.output).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.textTertiary).textSelection(.enabled)
                        }
                    }
                } else if failed {
                    WSEmptyState(symbol: "lock", title: String(localized: "Not available"),
                                 message: String(localized: "The Mac does not share this."))
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity).padding(.top, Theme.Spacing.xxxl)
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
        }
        .navigationTitle("Terminals")
        .screen()
        .task {
            while !Task.isCancelled {
                let loaded = await client.loadTerminals(sessionID)
                failed = loaded == nil
                if let loaded, loaded != terminals { terminals = loaded }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
}
