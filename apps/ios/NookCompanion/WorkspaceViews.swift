import SwiftUI

/// The session's menu for its files and terminals, where the Mac offers them.
struct SessionWorkspaceMenu: ViewModifier {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var showsFiles = false
    @State private var showsTerminals = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                if client.can(CompanionFeature.workspace) {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button { showsFiles = true } label: { Label("Files", systemImage: "folder") }
                            Button { showsTerminals = true } label: { Label("Terminals", systemImage: "terminal") }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Files and terminals")
                    }
                }
            }
            .navigationDestination(isPresented: $showsFiles) { SessionFilesView(sessionID: sessionID) }
            .navigationDestination(isPresented: $showsTerminals) { SessionTerminalsView(sessionID: sessionID) }
    }
}

/// A session's folder on the phone, to read. The Mac leaves out secrets by their name.
struct SessionFilesView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    var path = ""
    @State private var digest: FolderDigest?
    @State private var failed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                if let digest {
                    if digest.binary == true {
                        WSEmptyState(symbol: "doc", title: String(localized: "No text"),
                                     message: String(localized: "This file cannot be shown on the phone."))
                    } else if let text = digest.text {
                        Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(Theme.paper).textSelection(.enabled)
                        if digest.truncated == true {
                            Text("Only the start of this file is shown.").font(Theme.TextStyle.label).foregroundStyle(Theme.textTertiary)
                        }
                    } else {
                        ForEach(digest.entries ?? []) { entry in
                            NavigationLink {
                                SessionFilesView(sessionID: sessionID, path: path.isEmpty ? entry.name : path + "/" + entry.name)
                            } label: {
                                Label(entry.name, systemImage: entry.isFolder ? "folder" : "doc.text")
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
}

/// The terminals of a session's folder, to follow from the phone.
struct SessionTerminalsView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var terminals: [TerminalDigest]?

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
                if loaded != terminals { terminals = loaded ?? [] }
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }
}
