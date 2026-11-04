import SwiftUI
import VisionKit

struct RootView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.today
    @State private var todayPath: [String] = []
    @State private var sessionPath: [String] = []
    @State private var chatPath: [ChatRoute] = []
    @State private var inboxPath: [String] = []
    /// A quick action asked for a new session: the Agents tab opens its New session sheet.
    @State private var newSessionRequested = false

    enum Tab { case today, sessions, chats, nook, usage }

    var body: some View {
        Group {
            // Pairing another Mac shows the pairing screen too; the paired Macs stay.
            switch client.addingMac ? CompanionClient.Phase.unpaired : client.phase {
            case .unpaired, .pairing:
                PairingView()
            case .connected, .offline:
                TabView(selection: $tab) {
                    NavigationStack(path: $todayPath) {
                        TodayView(openChat: { prompt in
                            chatPath = [.new(UUID(), prompt)]
                            tab = .nook
                        }, openUsage: { tab = .usage }, newSession: {
                            sessionPath = []
                            tab = .sessions
                            newSessionRequested = true
                        }, openChats: {
                            inboxPath = []
                            tab = .chats
                        })
                    }
                    .tabItem { Label("Today", systemImage: "house.fill") }
                    .tag(Tab.today)
                    NavigationStack(path: $sessionPath) {
                        SessionListView(path: $sessionPath, newSessionRequested: $newSessionRequested)
                    }
                    .tabItem { Label("Agents", systemImage: "square.stack.3d.up.fill") }
                    .badge(client.sessions.needingYou)
                    .tag(Tab.sessions)
                    // A tab the Mac does not let this phone use (`CompanionScope`) is left out.
                    if client.allows(.chats) {
                        NavigationStack(path: $inboxPath) {
                            InboxListView(path: $inboxPath)
                        }
                        .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }
                        .badge(client.inboxUnread)
                        .tag(Tab.chats)
                    }
                    if client.allows(.nookChat) {
                        NavigationStack(path: $chatPath) {
                            ChatListView(path: $chatPath)
                        }
                        // Nook's own chats; "Chats" are your chat apps.
                        .tabItem { Label("Nook", systemImage: "sparkles") }
                        .tag(Tab.nook)
                    }
                    NavigationStack {
                        UsageScreen()
                    }
                    .tabItem { Label("Usage", systemImage: "chart.bar.fill") }
                    .tag(Tab.usage)
                }
            }
        }
        .tint(Theme.text)
        .preferredColorScheme(.dark)
        .background(Theme.canvas.ignoresSafeArea())
        .task { client.appBecameActive() }
        // A prompt link starts on the Agents tab, where its New session sheet opens.
        .onChange(of: client.pendingPrompt) { _, prompt in
            if prompt != nil { tab = .sessions }
        }
        // A quick action on the app's icon: start, ask, answer, or open a session.
        .onChange(of: client.pendingShortcut, initial: true) { _, shortcut in
            guard let shortcut else { return }
            client.pendingShortcut = nil
            switch shortcut {
            case .newSession:
                sessionPath = []
                tab = .sessions
                newSessionRequested = true
            case .askNook:
                if let blocked = QuickActionBlock.nook(client) {
                    client.notice = blocked
                } else {
                    chatPath = [.new(UUID(), "")]
                    tab = .nook
                }
            case .chats:
                if let blocked = QuickActionBlock.chats(client) {
                    client.notice = blocked
                } else {
                    inboxPath = []
                    tab = .chats
                }
            case .session(let id):
                client.openSession = id
            }
        }
        // The icon's quick actions follow the sessions: the ones that need you, then the newest.
        .onChange(of: client.sessions, initial: true) { _, sessions in AppShortcut.update(sessions: sessions) }
        // A tapped notification opens its session.
        .onChange(of: client.openSession) { _, id in
            guard let id else { return }
            tab = .sessions
            sessionPath = [id]
            client.openSession = nil
        }
        // Back in front: connect, or check the connection (replaced at once after a longer break, see CompanionWakeup).
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: client.appBecameActive()
            case .background: client.appWentToBackground()
            default: break
            }
        }
        .alert("", isPresented: Binding(get: { client.notice != nil }, set: { if !$0 { client.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(client.notice ?? "") }
    }
}

// MARK: Pairing

/// The welcome screen: what the app is, three steps, and one button.
struct PairingView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var text = ""
    @State private var scanning = false
    @State private var pasting = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xxl) {
                VStack(spacing: Theme.Spacing.lg) {
                    NookMark(size: 72)
                        .padding(.bottom, Theme.Spacing.md)
                    Text("Nook on your iPhone")
                        .font(Theme.TextStyle.display).foregroundStyle(Theme.text).multilineTextAlignment(.center)
                    Text("Follow your agents, approve what they ask, start new work, and chat with Nook.")
                        .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(.top, 56)

                // The Mac this iPhone was paired with removed it: pairing again is what is left to do.
                if let name = client.revokedMac {
                    Banner(text: String(localized: "\(name) removed this iPhone. Pair again to use it from here."),
                           symbol: "xmark.shield.fill", color: Theme.coral)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    PairingStep(number: 1, text: "On your Mac, open Nook › Settings › iPhone companion and turn it on.")
                    PairingStep(number: 2, text: "Choose ‘Pair an iPhone’: Nook shows a code for five minutes.")
                    PairingStep(number: 3, text: "Scan it here. Your phone and Mac need to be on the same Wi‑Fi.")
                }
                .card()

                VStack(spacing: Theme.Spacing.lg) {
                    if client.phase == .pairing {
                        ProgressView().controlSize(.large).frame(minHeight: 50)
                    } else if DataScannerViewController.isSupported {
                        Button { scanning = true } label: { Label("Scan the code", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    if pasting || !DataScannerViewController.isSupported {
                        VStack(spacing: Theme.Spacing.md) {
                            TextField("nook://pair?…", text: $text, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...4)
                                .font(Theme.TextStyle.code)
                                .padding(Theme.Spacing.lg)
                                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            Button("Pair") { client.pair(link: text) }
                                .buttonStyle(ActionButtonStyle(filled: true))
                                .disabled(text.isEmpty || client.phase == .pairing)
                        }
                        .card(padding: Theme.Spacing.lg)
                    } else {
                        Button("Paste the link instead") { withAnimation { pasting = true } }
                            .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    }
                    if client.addingMac {
                        Button("Cancel") { client.addingMac = false }
                            .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .screen()
        .sheet(isPresented: $scanning) {
            QRScanner { value in
                scanning = false
                client.pair(link: value)
            }
            .ignoresSafeArea()
        }
    }
}

private struct PairingStep: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            Text(number, format: .number)
                .font(Theme.rounded(13, .semibold)).foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .background(Theme.raised, in: Circle())
            Text(text).font(Theme.TextStyle.body).foregroundStyle(Theme.textStrong).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The camera, looking for a QR code.
struct QRScanner: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let code) in addedItems {
                if let value = code.payloadStringValue, value.hasPrefix("nook://pair") {
                    done = true
                    found(value)
                    return
                }
            }
        }
    }
}

// MARK: Sessions

/// Everything on the Mac at a glance, as the Mac's Agents tab: the panel's title row, what waits for you as notices
/// you answer right there, then the sessions that work and the recent ones as quiet rows.
struct SessionListView: View {
    @EnvironmentObject private var client: CompanionClient
    @ObservedObject private var live = LiveActivities.shared
    @Binding var path: [String]
    /// Set by a quick action elsewhere: open the New session sheet once.
    @Binding var newSessionRequested: Bool
    @State private var composing = false
    @State private var diagnosing = false
    /// The prompt link the open New session sheet was opened for.
    @State private var link: PromptLink?
    /// Words to find a session by (its title, folder, branch or agent), and the one project the list keeps to.
    @State private var query = ""
    @State private var project: String?

    /// Folders with sessions, the busiest first: the project filter's choices.
    private var projects: [String] {
        Dictionary(grouping: client.sessions, by: \.folder).sorted { $0.value.count > $1.value.count }.map(\.key)
    }

    private var ordered: [SessionDigest] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return client.sessions
            .filter { project == nil || $0.folder == project }
            .filter { session in
                words.isEmpty || [session.title, session.folder, session.branch ?? "", session.agent]
                    .contains { $0.localizedCaseInsensitiveContains(words) }
            }
            .sorted { $0.updated > $1.updated }
    }
    private var needsYou: [SessionDigest] { ordered.filter(Self.needsYou) }
    private var working: [SessionDigest] { ordered.filter { !Self.needsYou($0) && $0.attention == "working" } }
    private var rest: [SessionDigest] { ordered.filter { !Self.needsYou($0) && $0.attention != "working" } }

    static func needsYou(_ session: SessionDigest) -> Bool {
        !session.items.isEmpty || ["approval", "input", "failed", "limited"].contains(session.attention)
    }

    var body: some View {
        // A list, not a stack, so a row swipes to its actions as in Mail.
        List {
            Group {
                PanelHeader(title: "Agents", count: needsYou.count, subtitle: client.macName.isEmpty ? nil : client.macName) {
                    Menu {
                        // Sessions working on the Mac on the Lock Screen and in the Dynamic Island.
                        if client.can(CompanionFeature.liveActivity) {
                            Toggle(isOn: $live.enabled) { Label("Live Activities", systemImage: "platter.filled.top.iphone") }
                                .disabled(!live.allowedBySystem)
                        }
                        // How the phone reaches the Mac right now: the local network, Tailscale, or the relay.
                        if client.phase == .connected, let route = client.activeRoute {
                            Section { Label(RouteText.connected(route), systemImage: RouteText.symbol(route)) }
                        }
                        // Every paired Mac: the live connection goes to the one that is checked.
                        Section {
                            ForEach(client.macs) { mac in
                                Button { client.switchMac(to: mac.id) } label: {
                                    if mac.id == client.activeMacID {
                                        Label(mac.name, systemImage: "checkmark")
                                    } else {
                                        Label(mac.name, systemImage: "laptopcomputer")
                                    }
                                }
                            }
                            Button { client.addingMac = true } label: { Label("Pair another Mac", systemImage: "plus") }
                        }
                        Button { diagnosing = true } label: { Label("Check the connection", systemImage: "stethoscope") }
                        // Opens the update panel on the Mac; installing stays a click there.
                        if client.can(CompanionFeature.requestUpdate) {
                            Button { Task { await client.requestMacUpdate() } } label: {
                                Label("Show the update on your Mac", systemImage: "arrow.down.circle")
                            }
                        }
                        Button("Unpair from this Mac", role: .destructive) { client.unpair() }
                    } label: { NookIconLabel(symbol: "ellipsis") }
                    .accessibilityLabel("More")
                    // Always in sight: a Mac that does not allow it (yet) says why instead.
                    NookIconButton(symbol: "square.and.pencil", label: "New session") { newSession() }
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ConnectionLine()
                    // New sessions written while the Mac could not be reached: they start once it answers.
                    ForEach(client.outbox.starts) { entry in
                        WaitingRow(symbol: "square.and.pencil", title: entry.request.launch?.task ?? "",
                                   detail: String(localized: "New session · waiting for your Mac")) { client.discardWaiting(entry.id) }
                    }
                    // Finding one among many by search and project scope: words, and the project as chips.
                    if client.sessions.count > 4 {
                        NookSearchField(prompt: "Search sessions", text: $query)
                        if projects.count > 1 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: Theme.Spacing.md) {
                                    FilterChip(title: "All", selected: project == nil) { project = nil }
                                    ForEach(projects, id: \.self) { folder in
                                        FilterChip(title: LocalizedStringKey(folder), count: client.sessions.filter { $0.folder == folder }.count,
                                                   selected: project == folder) { project = project == folder ? nil : folder }
                                    }
                                }
                            }
                        }
                    }
                    if ordered.isEmpty, !client.sessions.isEmpty {
                        Text("No session matches.")
                            .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
                    }
                    if client.macPushReady == false {
                        Banner(text: String(localized: "Push notifications are not ready on your Mac yet (Settings › iPhone companion)."),
                               symbol: "bell.slash.fill", color: Theme.textSecondary)
                    }
                    ForEach(needsYou) { session in SessionNotice(session: session) { path.append(session.id) } }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                group("Working", working)
                group("Recent", rest)
                otherMacs
                if client.sessions.isEmpty, client.phase == .connected {
                    EmptyState(symbol: "square.stack.3d.up", title: "No sessions",
                               message: "Sessions of your coding agents on your Mac show up here.") {
                        Button { newSession() } label: { Label("New session", systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                }
                Color.clear.frame(height: Theme.Spacing.xxl)
            }
            .panelRow()
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .refreshable { await client.refresh() }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
        .sheet(isPresented: $composing, onDismiss: { link = nil }) {
            NewSessionView(link: link) { id in path.append(id) }
        }
        .sheet(isPresented: $diagnosing) { DiagnosisSheet() }
        .onChange(of: newSessionRequested, initial: true) { _, requested in
            guard requested else { return }
            newSessionRequested = false
            newSession()
        }
        // An opened nook://prompt link: the New session sheet with its text, never started by itself.
        .onChange(of: client.pendingPrompt, initial: true) { _, prompt in
            guard let prompt else { return }
            guard client.can(CompanionFeature.start) else {
                client.pendingPrompt = nil
                client.notice = String(localized: "This Mac cannot start sessions from the phone yet. Update Nook on your Mac.")
                return
            }
            link = prompt
            composing = true
            client.pendingPrompt = nil
        }
        .screen()
    }

    /// The New session sheet, or why this Mac does not let the phone start one.
    private func newSession() {
        if let blocked = QuickActionBlock.session(client) {
            client.notice = blocked
        } else {
            composing = true
        }
    }

    /// The sessions of every other paired Mac, under its name: what waits there first. A tap makes that Mac the active
    /// one and opens the session once its list is in.
    @ViewBuilder
    private var otherMacs: some View {
        ForEach(client.macs.filter { $0.id != client.activeMacID }) { mac in
            let sessions = (client.otherSessions[mac.id] ?? []).sorted {
                (Self.needsYou($0) ? 1 : 0, $0.updated) > (Self.needsYou($1) ? 1 : 0, $1.updated)
            }
            if !sessions.isEmpty {
                SectionHeader(title: "On \(mac.name)", count: sessions.filter(Self.needsYou).count, urgent: sessions.contains(where: Self.needsYou))
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xs)
                ForEach(sessions.prefix(10)) { session in
                    Button {
                        client.switchMac(to: mac.id)
                        path.append(session.id)
                    } label: { AgentRow(session: session) }
                        .buttonStyle(RowPress())
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.xxs / 2)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ sessions: [SessionDigest]) -> some View {
        if !sessions.isEmpty {
            SectionHeader(title: title, count: sessions.count)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xs)
            ForEach(sessions) { session in
                Button { path.append(session.id) } label: { AgentRow(session: session) }
                    .buttonStyle(RowPress())
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.vertical, Theme.Spacing.xxs / 2)
                    .contextMenu { SessionQuickActions(session: session) }
                    .sessionSwipeActions(session)
            }
        }
    }
}

extension View {
    /// A row of a panel built as a `List`: edge to edge on the canvas, without the list's own separator or inset.
    func panelRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// A session row's swipes: to the left archive (or end an agent outside Nook), to the
    /// right snooze it for an hour (or wake it). Long press shows them all.
    func sessionSwipeActions(_ session: SessionDigest) -> some View {
        modifier(SessionSwipes(session: session))
    }
}

private struct SessionSwipes: ViewModifier {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    private var actions: [SessionAction] {
        client.can(CompanionFeature.manage) ? (session.actions ?? []).compactMap(SessionAction.init(rawValue:)) : []
    }

    func body(content: Content) -> some View {
        content
            .panelRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if actions.contains(.archive) {
                    Button { run(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                        .tint(Theme.raised)
                }
                if actions.contains(.end) {
                    Button(role: .destructive) { run(.end) } label: { Label("End session", systemImage: "xmark.circle") }
                        .tint(Theme.coral)
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if actions.contains(.unsnooze) {
                    Button { run(.unsnooze) } label: { Label("Cancel snooze", systemImage: "alarm") }
                        .tint(Theme.blue)
                } else if actions.contains(.snoozeHour) {
                    Button { run(.snoozeHour) } label: { Label("Snooze", systemImage: "clock") }
                        .tint(Theme.amber)
                }
            }
    }

    private func run(_ action: SessionAction) {
        Haptics.tap()
        Task { await client.manage(session, action) }
    }
}

/// A row's actions under a long press, the phone's form of the buttons the Mac shows on a row under the pointer: snooze
/// or wake it, archive it, or end an agent outside Nook. Rename and stop live on the session's own screen.
struct SessionQuickActions: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    private var actions: [SessionAction] {
        client.can(CompanionFeature.manage) ? (session.actions ?? []).compactMap(SessionAction.init(rawValue:)) : []
    }

    var body: some View {
        if actions.contains(.unsnooze) {
            Button { run(.unsnooze) } label: { Label("Cancel snooze", systemImage: "alarm") }
        } else if actions.contains(.snoozeHour) {
            Menu {
                Button("One hour") { run(.snoozeHour) }
                Button("This evening") { run(.snoozeEvening) }
                Button("Tomorrow morning") { run(.snoozeTomorrow) }
            } label: { Label("Snooze", systemImage: "clock") }
        }
        if actions.contains(.archive) {
            Button(role: .destructive) { run(.archive) } label: { Label("Archive", systemImage: "archivebox") }
        }
        if actions.contains(.end) {
            Button(role: .destructive) { run(.end) } label: { Label("End session", systemImage: "xmark.circle") }
        }
    }

    private func run(_ action: SessionAction) {
        Haptics.tap()
        Task { await client.manage(session, action) }
    }
}

/// Only while the Mac does not answer: why, in one quiet line (the Mac's name is in the title row).
struct ConnectionLine: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var diagnosing = false

    var body: some View {
        // A Mac removed this iPhone (`CompanionResponse.revoked`) while another paired Mac is still here.
        if let name = client.revokedMac {
            Banner(text: String(localized: "\(name) removed this iPhone. Pair again to use it from here."),
                   symbol: "xmark.shield.fill", color: Theme.coral)
            HStack(spacing: Theme.Spacing.md) {
                Button("Pair again") {
                    client.revokedMac = nil
                    client.addingMac = true
                }
                .buttonStyle(ActionButtonStyle())
                Button("Not now") { client.revokedMac = nil }
                    .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
            }
        }
        if case .offline(let reason) = client.phase {
            // What shows is what the Mac said last, not what happens now.
            if let updated = client.lastUpdated, !client.sessions.isEmpty {
                Banner(text: String(localized: "Last updated \(updated.formatted(date: .omitted, time: .shortened)) · not connected"),
                       symbol: "clock.arrow.circlepath", color: Theme.textSecondary)
            }
            Banner(text: reason.isEmpty ? String(localized: "Looking for your Mac…") : reason, symbol: "wifi.slash")
            if let hint = client.awayHint { Banner(text: hint, symbol: "globe") }
            Button { diagnosing = true } label: { Label("Why can't I connect?", systemImage: "stethoscope") }
                .buttonStyle(ActionButtonStyle())
                .sheet(isPresented: $diagnosing) { DiagnosisSheet() }
        }
        // The Mac and this app are too far apart in version for some of what the phone does (`CompanionCompatibility`).
        switch client.compatibility {
        case .macTooOld:
            Banner(text: String(localized: "Update Nook on your Mac: it is too old for this version of the app."),
                   symbol: "arrow.down.circle.fill")
        case .phoneTooOld:
            Banner(text: String(localized: "Update the app: Nook on your Mac needs a newer Nook Companion."),
                   symbol: "arrow.down.circle.fill")
        case .ok where client.hasUnrecognizedMacFeatures:
            Banner(text: String(localized: "Update Nook Companion to use everything your Mac offers."),
                   symbol: "arrow.down.circle.fill")
        case .ok:
            EmptyView()
        }
    }
}

/// Something you wrote that waits on the phone for the Mac (`CompanionOutbox`): what it is, that it waits, and (long
/// press) a way to let it go.
struct WaitingRow: View {
    let symbol: String
    let title: String
    let detail: String
    let discard: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: symbol).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title).font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Label(detail, systemImage: "clock").font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: Theme.Spacing.md)
        }
        .card(padding: Theme.Spacing.lg)
        .contextMenu {
            Button(role: .destructive, action: discard) { Label("Don’t send", systemImage: "trash") }
        }
    }
}

/// A session in a list, the Mac's `AgentListRow`: its name with the status (or how long ago) on the right, and where it
/// works with the agent's logo underneath. A row that asks nothing of you recedes, so what needs you is the only loud
/// thing.
struct AgentRow: View {
    let session: SessionDigest

    private var receded: Bool { !SessionListView.needsYou(session) && session.attention != "working" }
    private var context: String {
        guard let branch = session.branch, !branch.isEmpty else { return session.folder }
        return session.folder + " · " + branch
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.md) {
                Text(session.title)
                    .font(receded ? Theme.TextStyle.body : Theme.TextStyle.strong)
                    .foregroundStyle(receded ? Theme.textSecondary : Theme.text)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.md)
                slot
            }
            HStack(spacing: Theme.Spacing.md) {
                Text(context).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.md)
                AgentMark(agent: session.agent, size: 15, quiet: true)
            }
            .font(Theme.TextStyle.detail)
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md + Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The status where it says something (working, waiting, failed, ready), otherwise how long ago.
    @ViewBuilder
    private var slot: some View {
        if ["working", "ready"].contains(session.attention) || Theme.needsYou(session.attention) {
            StatusPill(attention: session.attention)
        } else {
            Text(Date(timeIntervalSince1970: session.updated), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }
}

/// A session that waits for you, the Mac's `PanelNoticeBar`: whose it is, what it asks, and its answer right there
/// (Allow with Deny beside it in one pill, or Answer); a tap on its top opens the session.
struct SessionNotice: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    /// Opens the session; nil uses a navigation link (a list row needs a plain button, or the whole row becomes one link).
    var open: (() -> Void)? = nil

    private var item: SessionDigest.Item? { session.items.first }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            opener {
                HStack(spacing: Theme.Spacing.md) {
                    AgentMark(agent: session.agent, size: 15)
                    Text(session.title).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.md)
                    StatusPill(attention: session.attention)
                }
                .contentShape(Rectangle())
            }

            if let item {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(item.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(4)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(Theme.TextStyle.code).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    }
                }
                actions(item)
            } else if !session.excerpt.isEmpty {
                Text(session.excerpt).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
            .strokeBorder(Theme.color(session.attention).opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private func opener<Label: View>(@ViewBuilder _ label: () -> Label) -> some View {
        if let open {
            Button(action: open, label: label).buttonStyle(PressFade())
        } else {
            NavigationLink(value: session.id, label: label).buttonStyle(PressFade())
        }
    }

    @ViewBuilder
    private func actions(_ item: SessionDigest.Item) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            switch item.kind {
            case _ where !client.allows(.approve):
                ApproveOffLabel()
            case .approval:
                if item.canAllow {
                    NookSplitButton(primary: NoticeAction(label: "Allow", symbol: "checkmark") {
                        Haptics.success(); Task { await client.decide(session, item: item, allow: true) }
                    }, secondary: NoticeAction(label: "Deny") {
                        Haptics.warning(); Task { await client.decide(session, item: item, allow: false) }
                    })
                } else {
                    Button("Deny") { Haptics.warning(); Task { await client.decide(session, item: item, allow: false) } }
                        .buttonStyle(ActionButtonStyle(color: Theme.coral))
                        .fixedSize()
                    Label("Only on your Mac: this one is risky or unknown.", systemImage: "lock.fill")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                }
            case .question:
                opener {
                    Text("Answer").font(Theme.TextStyle.strong).foregroundStyle(Theme.ink)
                        .padding(.horizontal, Theme.Spacing.xl + Theme.Spacing.xxs)
                        .frame(height: 42)
                        .background(Theme.text, in: Capsule())
                }
            }
            Spacer(minLength: 0)
            if session.items.count > 1 {
                Text("and \(session.items.count - 1) more").font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// How the phone reaches the Mac, in words and a symbol.
enum RouteText {
    static func connected(_ route: CompanionRoute) -> String {
        if route.isRelay { return String(localized: "Connected through your relay") }
        switch route.kind {
        case .tailnet: return String(localized: "Connected over Tailscale")
        case .vpn: return String(localized: "Connected over a VPN")
        case .internet: return String(localized: "Connected over the internet")
        case .lan, .loopback: return String(localized: "Connected over your local network")
        }
    }

    static func symbol(_ route: CompanionRoute) -> String {
        if route.isRelay { return "globe" }
        switch route.kind {
        case .tailnet, .vpn: return "lock.shield"
        case .internet: return "globe"
        case .lan, .loopback: return "wifi"
        }
    }
}
