import AppKit
import Combine
import SwiftUI

/// The local servers this session's folder runs, as small buttons in a bar above the browser (`SidePanelToolbar`):
/// one tap opens it. Checked every few seconds while the browser is open; without any there is no bar.
struct DevServerStrip: View {
    let directory: String
    @ObservedObject var browser: BrowserStore
    @State private var servers: [DevServer] = []
    /// Why a server has no Stop: shown under the bar after a tap on its stop button.
    @State private var note: String?
    /// Bumped after a stop, so the scan looks again at once.
    @State private var rescan = 0

    var body: some View {
        // A VStack, not a Group: it exists while still empty, so the scan below starts.
        VStack(alignment: .leading, spacing: 0) {
            if !servers.isEmpty {
                SidePanelToolbar {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: NookTheme.Spacing.sm) {
                            Image(icon: "dot.radiowaves.left.and.right")
                                .font(NookTheme.font(10, .semibold))
                                .foregroundStyle(NookTheme.textTertiary)
                                .help(tr("agents.servers.help"))
                            ForEach(servers) { server in
                                // `address` is published, unlike the web view's own URL.
                                let open = URL(string: browser.address)?.port == server.port
                                Button {
                                    browser.go(server.url.absoluteString)
                                } label: {
                                    Text("\(server.command) — :\(server.port)")
                                        .font(NookTheme.TextStyle.label)
                                        .foregroundStyle(open ? NookTheme.paper : NookTheme.textSecondary)
                                        .padding(.horizontal, 9)
                                        .frame(height: 22)
                                        .background(NookTheme.shape(NookTheme.Radius.control).fill(open ? NookTheme.smoke : NookTheme.field))
                                }
                                .buttonStyle(.nookPlain)
                                .help(server.url.absoluteString)
                                if server.pid > 0 { stopButton(server) }
                            }
                        }
                    }
                }
                if let note {
                    Text(note)
                        .font(NookTheme.TextStyle.caption)
                        .foregroundStyle(NookTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NookTheme.Spacing.md)
                        .padding(.bottom, NookTheme.Spacing.sm)
                        .transition(.opacity)
                }
            }
        }
        .task(id: ScanKey(directory: directory, rescan: rescan)) {
            let folder = WorkspacePathPolicy.normalize(directory)
            // Each scan starts `lsof` twice (100–500 ms of work). Every 3 seconds right after something changed, so a
            // server that just started shows up at once; up to every 15 seconds while the list stays the same.
            var wait: UInt64 = 3
            while !Task.isCancelled {
                let shells = TerminalStore.shared.sessions.map(\.shellPID)
                let found = await Task.detached(priority: .utility) { () async -> [DevServer] in
                    // Only listeners that serve a page: not the folder's database or debugger.
                    var servers = await DevServerProbe.pages(DevServerScanner.scan(folder: folder))
                    servers = DevServerOwnership.mark(servers, roots: .current(shells: shells))
                    // Pages the project names (nook.json previewUrl) on localhost, when they are not already found.
                    for script in ProjectScripts.load(folder: folder) {
                        guard let url = script.previewURL, let port = url.port, BridgeURLPolicy.isLoopback(url.host ?? ""),
                              !servers.contains(where: { $0.port == port }) else { continue }
                        servers.append(DevServer(pid: 0, command: script.name, port: port))
                    }
                    return servers.sorted { $0.port < $1.port }
                }.value
                if found != servers {
                    withAnimation(NookTheme.reveal) { servers = found }
                    wait = 3
                } else {
                    wait = min(wait + 3, 15)
                }
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
            }
        }
    }

    private struct ScanKey: Equatable {
        var directory: String
        var rescan: Int
    }

    /// Stops a server Nook started; for any other server it says why not, since stopping something you run elsewhere
    /// would take it away behind your back.
    private func stopButton(_ server: DevServer) -> some View {
        Button {
            guard server.startedByNook else {
                withAnimation(NookTheme.reveal) {
                    note = note == nil ? tr("automation.server.notOurs", server.command, String(server.port)) : nil
                }
                return
            }
            let shells = TerminalStore.shared.sessions.map(\.shellPID)
            Task {
                let stopped = await Task.detached(priority: .userInitiated) {
                    DevServerOwnership.stop(server, roots: .current(shells: shells))
                }.value
                withAnimation(NookTheme.reveal) {
                    note = stopped ? nil : tr("automation.server.notOurs", server.command, String(server.port))
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                rescan += 1
            }
        } label: {
            Image(icon: "stop.fill")
                .font(NookTheme.font(8, .semibold))
                .foregroundStyle(server.startedByNook ? NookTheme.textSecondary : NookTheme.textTertiary)
                .frame(width: 18, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.nookPlain)
        .help(server.startedByNook ? tr("automation.server.stop", String(server.port)) : tr("automation.server.stopUnavailable"))
        .accessibilityLabel(tr("automation.server.stop", String(server.port)))
    }
}
