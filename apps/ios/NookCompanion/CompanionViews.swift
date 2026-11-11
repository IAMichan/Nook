import SwiftUI
import VisionKit

struct RootView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var router = TabRouter()
    @State private var sessionPath: [String] = []
    @State private var chatPath: [ChatRoute] = []
    @State private var inboxPath: [String] = []
    /// A quick action asked for a new session: the Agents tab opens its New session sheet.
    @State private var newSessionRequested = false
    /// The launch screen (`LaunchView`) over everything while the app opens, until the Mac answers or a moment passes.
    @State private var launching = true

    var body: some View {
        Group {
            // Pairing another Mac shows the pairing screen too; the paired Macs stay.
            switch client.addingMac ? CompanionClient.Phase.unpaired : client.phase {
            case .unpaired, .pairing:
                PairingView()
            case .connected, .offline:
                // The tabs along the bottom, as t3code's iPhone app: Nook, Agents, Chats, pull requests and Settings,
                // each with what waits there as a badge. Each tab keeps where it was.
                let available = router.available(client)
                TabView(selection: $router.tab) {
                    if available.contains(.nook) {
                        NavigationStack(path: $chatPath) { ChatListView(path: $chatPath) }
                            .tabItem { tabLabel(.nook) }
                            .tag(CompanionTab.nook)
                            .badge(router.count(.nook, client))
                    }
                    NavigationStack(path: $sessionPath) {
                        SessionListView(path: $sessionPath, newSessionRequested: $newSessionRequested)
                    }
                    .tabItem { tabLabel(.agents) }
                    .tag(CompanionTab.agents)
                    .badge(router.count(.agents, client))
                    if available.contains(.chats) {
                        NavigationStack(path: $inboxPath) { InboxListView(path: $inboxPath) }
                            .tabItem { tabLabel(.chats) }
                            .tag(CompanionTab.chats)
                            .badge(router.count(.chats, client))
                    }
                    if available.contains(.pulls) {
                        NavigationStack { PullRequestListView() }
                            .tabItem { tabLabel(.pulls) }
                            .tag(CompanionTab.pulls)
                    }
                    NavigationStack { SettingsView() }
                        .tabItem { tabLabel(.settings) }
                        .tag(CompanionTab.settings)
                }
                .environmentObject(router)
                // A tab the Mac no longer allows falls back to Agents.
                .onChange(of: available) { _, tabs in
                    if !tabs.contains(router.tab) { router.tab = .agents }
                }
                .onChange(of: router.tab) { _, _ in Haptics.tap() }
            }
        }
        .tint(Theme.paper)
        .preferredColorScheme(.dark)
        .background(Theme.canvas.ignoresSafeArea())
        .overlay {
            if launching {
                LaunchView(macName: client.macName, paired: client.phase != .unpaired)
                    .transition(.opacity)
            }
        }
        .task { client.appBecameActive() }
        .task { await finishLaunch() }
        #if DEBUG
        // `-NookDemoShow agents|chats|session|chat` with `-NookDemo`: opens that screen of the demo.
        .task {
            switch UserDefaults.standard.string(forKey: "NookDemoShow") {
            case "agents": router.tab = .agents
            case "session": router.tab = .agents; sessionPath = ["s2"]
            case "chats": router.tab = .chats
            case "chat": router.tab = .chats; inboxPath = ["w1"]
            default: break
            }
        }
        #endif
        // A prompt link starts on the Agents tab, where its New session sheet opens.
        .onChange(of: client.pendingPrompt) { _, prompt in
            if prompt != nil { router.tab = .agents }
        }
        // A quick action on the app's icon: start, ask, answer, or open a session.
        .onChange(of: client.pendingShortcut, initial: true) { _, shortcut in
            guard let shortcut else { return }
            client.pendingShortcut = nil
            switch shortcut {
            case .newSession:
                sessionPath = []
                router.tab = .agents
                newSessionRequested = true
            case .askNook:
                if let blocked = QuickActionBlock.nook(client) {
                    client.notice = blocked
                } else {
                    chatPath = [.new(UUID(), "")]
                    router.tab = .nook
                }
            case .chats:
                if let blocked = QuickActionBlock.chats(client) {
                    client.notice = blocked
                } else {
                    inboxPath = []
                    router.tab = .chats
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
            router.tab = .agents
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
        .sheet(item: $client.snoozing) { session in SnoozeSheet(session: session) }
        .alert("", isPresented: Binding(get: { client.notice != nil }, set: { if !$0 { client.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(client.notice ?? "") }
    }

    /// Holds the launch screen for at least a short moment, so it does not flash, and, with a paired Mac, until it
    /// answers or `LaunchView.maxWait` passes: then the tabs show what was kept, marked as not live.
    private func finishLaunch() async {
        let start = ContinuousClock.now
        try? await Task.sleep(for: LaunchView.minShown)
        while !Task.isCancelled, client.phase != .connected, client.phase != .unpaired,
              ContinuousClock.now - start < LaunchView.maxWait {
            try? await Task.sleep(for: .milliseconds(100))
        }
        withAnimation(.easeOut(duration: 0.3)) { launching = false }
    }

    /// A tab's icon and name in the bar along the bottom.
    private func tabLabel(_ tab: CompanionTab) -> some View {
        Label {
            Text(tab.title)
        } icon: {
            Image(icon: tab.symbol(selected: router.tab == tab))
        }
    }
}

// MARK: Quick actions

/// Why the phone cannot do one of the three things it starts (a session, a question to Nook, an answer in a chat), in
/// words that say how to change it; nil when it can. An action the Mac does not allow stays in sight and says this when
/// tapped, so nothing you look for has quietly disappeared.
enum QuickActionBlock {
    @MainActor
    static func session(_ client: CompanionClient) -> String? {
        if !client.allows(.operate) { return String(localized: "Starting sessions is turned off for this iPhone in Nook on your Mac.") }
        if !client.can(CompanionFeature.start) { return String(localized: "This Mac cannot start sessions from the phone yet. Update Nook on your Mac.") }
        return nil
    }

    @MainActor
    static func nook(_ client: CompanionClient) -> String? {
        if !client.allows(.nookChat) { return String(localized: "Chatting with Nook is turned off for this iPhone in Nook on your Mac.") }
        if !client.can(CompanionFeature.chat) { return String(localized: "Update Nook on your Mac to chat with Nook from your phone.") }
        return nil
    }

    @MainActor
    static func chats(_ client: CompanionClient) -> String? {
        if !client.allows(.chats) { return String(localized: "Chats are turned off for this iPhone in Nook on your Mac.") }
        if !client.can(CompanionFeature.inbox) { return String(localized: "Update Nook on your Mac to read and answer your chats from your phone.") }
        return nil
    }
}

// MARK: Pairing

/// The welcome screen: what the app is, three steps, and one button.
/// What shows while the app opens: Nook with a calm glow and, with a paired Mac, that it is reaching it. Drawn on the
/// same canvas as the system's launch screen (`LaunchBackground`), so the opening has no flash.
struct LaunchView: View {
    let macName: String
    let paired: Bool

    static let minShown = Duration.milliseconds(700)
    static let maxWait = Duration.seconds(4)

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            NookMark(size: 72)
                .background(NookAura(size: 240))
            VStack(spacing: Theme.Spacing.md) {
                ProgressView().tint(Theme.textSecondary)
                Text(status)
                    .font(Theme.TextStyle.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        guard paired else { return String(localized: "Starting Nook…") }
        return macName.isEmpty ? String(localized: "Connecting to your Mac…") : String(localized: "Connecting to \(macName)…")
    }
}

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
                        .background(NookAura(size: 240))
                        .padding(.bottom, Theme.Spacing.md)
                    Text("Nook on your iPhone")
                        .font(Theme.TextStyle.display).foregroundStyle(Theme.paper).multilineTextAlignment(.center)
                    Text("Follow your agents, approve what they ask, start new work, and chat with Nook.")
                        .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(.top, 56)

                // The Mac this iPhone was paired with removed it: pairing again is what is left to do.
                if let name = client.revokedMac {
                    Banner(text: String(localized: "\(name) removed this iPhone. Pair again to use it from here."),
                           symbol: "xmark.shield.fill", color: Theme.coral)
                }

                VStack(alignment: .leading, spacing: 0) {
                    PairingStep(number: 1, text: "On your Mac, open Nook › Settings › iPhone companion and turn it on.")
                    PairingStep(number: 2, text: "Choose ‘Pair an iPhone’: Nook shows a code for five minutes.")
                    PairingStep(number: 3, text: "Scan it here. Your phone and Mac need to be on the same Wi‑Fi.", last: true)
                }
                .card()

                VStack(spacing: Theme.Spacing.lg) {
                    if client.phase == .pairing {
                        ProgressView().controlSize(.large).frame(minHeight: 50)
                    } else if DataScannerViewController.isSupported {
                        NookPrimaryButton(title: String(localized: "Scan the code"), symbol: "qrcode.viewfinder") { scanning = true }
                    }
                    if pasting || !DataScannerViewController.isSupported {
                        VStack(spacing: Theme.Spacing.md) {
                            TextField("nook://pair?…", text: $text, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...4)
                                .font(Theme.TextStyle.code)
                                .padding(Theme.Spacing.lg)
                                .roundedBackground(Theme.well, radius: Theme.Radius.control)
                            NookPrimaryButton(title: String(localized: "Pair")) { client.pair(link: text) }
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

            Label {
                Text("Everything between your iPhone and your Mac is encrypted end to end.")
            } icon: {
                Image(icon: "lock.shield")
            }
                .font(Theme.TextStyle.detail)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
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
    /// The last step has no line down to a next one.
    var last = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            Text(number, format: .number)
                .font(Theme.rounded(13, .bold)).foregroundStyle(Theme.paper)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(Theme.smoke)
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                )
            Text(text)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.textStrong)
                .lineSpacing(2)
                .padding(.top, Theme.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, last ? 0 : Theme.Spacing.xl)
        // The steps hang on one thin line, from under this number down to the next.
        .overlay(alignment: .topLeading) {
            if !last {
                Rectangle()
                    .fill(Theme.line2)
                    .frame(width: 1)
                    .padding(.top, 28 + Theme.Spacing.xs)
                    .padding(.bottom, Theme.Spacing.xs)
                    .padding(.leading, 13.5)
            }
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
    @Binding var path: [String]
    /// Set by a quick action elsewhere: open the New session sheet once.
    @Binding var newSessionRequested: Bool
    @State private var composing = false
    /// The prompt link the open New session sheet was opened for.
    @State private var link: PromptLink?
    /// Words to find a session by (its title, folder, branch or agent).
    @State private var query = ""
    /// Recent sessions beyond the first few, shown on request so the list stays short.
    @State private var showsAllRecent = false
    /// The Working and Recent shelves, open or folded; remembered.
    @AppStorage("nook.companion.shelf.working") private var workingOpen = true
    @AppStorage("nook.companion.shelf.recent") private var recentOpen = true
    @AppStorage("nook.companion.shelf.older") private var olderOpen = true

    private var ordered: [SessionDigest] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return client.sessions
            .filter { session in
                words.isEmpty || [session.title, session.folder, session.branch ?? "", session.agent]
                    .contains { $0.localizedCaseInsensitiveContains(words) }
            }
            .sorted { $0.updated > $1.updated }
    }
    private var needsYou: [SessionDigest] { ordered.filter(Self.needsYou) }
    private var working: [SessionDigest] { ordered.filter { !Self.needsYou($0) && $0.attention == "working" } }
    private var rest: [SessionDigest] { ordered.filter { !Self.needsYou($0) && $0.attention != "working" } }
    /// Settled sessions older than the live list, paged in from the Mac (`CompanionFeature.history`).
    private var older: [SessionDigest] { CompanionHistory.merge(live: client.sessions, older: client.olderSessions) }
    /// What the Mac found for the words beyond what the live list already shows.
    private var foundOlder: [SessionDigest] {
        guard client.foundQuery == CompanionHistory.clean(query) else { return [] }
        return CompanionHistory.merge(live: client.sessions, older: client.foundSessions)
    }
    /// The Mac holds more sessions than the live list: older ones can be paged in.
    private var hasOlder: Bool {
        client.can(CompanionFeature.history) && client.sessions.count >= CompanionHistory.liveCount
            && (!client.olderEnded || !client.olderSessions.isEmpty)
    }

    /// How many recent sessions show before "Show more".
    private static let recentShown = 8

    static func needsYou(_ session: SessionDigest) -> Bool {
        !session.items.isEmpty || ["approval", "input", "failed", "limited"].contains(session.attention)
    }

    var body: some View {
        // A list, not a stack, so a row swipes to its actions as in Mail.
        List {
            Group {
                PanelHeader {
                    // Always in sight: a Mac that does not allow it (yet) says why instead.
                    NookIconButton(systemName: "square.and.pencil", label: String(localized: "New session")) { newSession() }
                }
                .buttonStyle(.borderless)
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ConnectionLine()
                    // New sessions written while the Mac could not be reached: they start once it answers.
                    ForEach(client.outbox.starts) { entry in
                        WaitingRow(symbol: "square.and.pencil", title: entry.request.launch?.task ?? "",
                                   detail: String(localized: "New session · waiting for your Mac")) { client.discardWaiting(entry.id) }
                    }
                    // Finding one among many: words that match its title, folder, branch or agent.
                    // With a Mac that searches its older sessions too, also while the list is short.
                    if client.sessions.count > 8 || hasOlder {
                        NookSearchField(prompt: "Search sessions", text: $query)
                    }
                    if ordered.isEmpty, foundOlder.isEmpty, !client.sessions.isEmpty {
                        Text("No session matches.")
                            .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, Theme.Spacing.xxl)
                    }
                    ForEach(needsYou) { session in SessionNotice(session: session) { path.append(session.id) } }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                group(String(localized: "Working"), working, open: $workingOpen)
                group(String(localized: "Recent"), showsAllRecent || !query.isEmpty ? rest : Array(rest.prefix(Self.recentShown)), total: rest.count,
                      open: $recentOpen)
                if recentOpen, rest.count > Self.recentShown, !showsAllRecent, query.isEmpty {
                    Button { withAnimation(Theme.reveal) { showsAllRecent = true } } label: {
                        Text("Show \(rest.count - Self.recentShown) more")
                            .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                    }
                    .buttonStyle(PressFade())
                    .padding(.horizontal, Theme.Spacing.xl)
                }
                olderShelves
                otherMacs
                if client.sessions.isEmpty, client.phase == .connected {
                    WSEmptyState(symbol: "square.stack.3d.up", title: String(localized: "No sessions"),
                                 message: String(localized: "Sessions of your coding agents on your Mac show up here."),
                                 action: (String(localized: "New session"), { newSession() }))
                }
                Color.clear.frame(height: Theme.Spacing.xxl)
            }
            .panelRow()
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .animation(Theme.reveal, value: client.sessions)
        .refreshable { await client.refresh() }
        // The words go to the Mac once you pause typing, for the sessions older than the live list.
        .task(id: query) {
            guard client.can(CompanionFeature.history) else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await client.searchSessions(query)
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
        .sheet(isPresented: $composing, onDismiss: { link = nil }) {
            NewSessionView(link: link) { id in path.append(id) }
        }
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

    /// Below the recent sessions, as the Mac's settled sessions: the older ones, a page at a time, or while searching,
    /// the older ones that match.
    @ViewBuilder
    private var olderShelves: some View {
        if !query.isEmpty {
            group(String(localized: "Older matches"), foundOlder, open: $olderOpen)
            if olderOpen, client.foundCursor != nil, !foundOlder.isEmpty {
                PageButton(title: String(localized: "More matches")) { await client.searchSessions(query, more: true) }
                    .padding(.horizontal, Theme.Spacing.xl)
            }
        } else if hasOlder, recentOpen, showsAllRecent || rest.count <= Self.recentShown {
            group(String(localized: "Older"), older, open: $olderOpen)
            if olderOpen || older.isEmpty, !client.olderEnded {
                PageButton(title: older.isEmpty ? String(localized: "Show older sessions") : String(localized: "Show more older sessions")) {
                    await client.loadOlderSessions()
                }
                .padding(.horizontal, Theme.Spacing.xl)
            }
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
                SectionHeader(title: String(localized: "On \(mac.name)"), count: sessions.filter(Self.needsYou).count, urgent: sessions.contains(where: Self.needsYou))
                    .padding(.horizontal, Theme.Spacing.md)
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

    /// A shelf of sessions, as the Mac's Agents list: its header folds it; the rows stand without lines between them,
    /// and only the one under your finger lifts.
    @ViewBuilder
    private func group(_ title: String, _ sessions: [SessionDigest], total: Int? = nil, open: Binding<Bool>) -> some View {
        if !sessions.isEmpty {
            SectionHeader(title: title, count: total ?? sessions.count, expanded: open)
                .padding(.horizontal, Theme.Spacing.md)
            if open.wrappedValue {
                ForEach(sessions) { session in
                    Button { path.append(session.id) } label: { AgentRow(session: session) }
                        .buttonStyle(RowPress())
                        .padding(.horizontal, Theme.Spacing.md)
                        .contextMenu { SessionQuickActions(session: session) }
                        .sessionSwipeActions(session)
                }
            }
        }
    }
}

/// "Show older sessions": asks for the next page, with a spinner instead of its words while it loads.
private struct PageButton: View {
    let title: String
    let load: () async -> Void
    @State private var loading = false

    var body: some View {
        Button {
            guard !loading else { return }
            loading = true
            Task {
                await load()
                loading = false
            }
        } label: {
            Group {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(title).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(PressFade())
        .disabled(loading)
    }
}

extension View {
    /// Shows this only after it stayed for a moment (0.8 s), fading in, so a state that passes quickly never flickers.
    func appearsAfterDelay() -> some View { modifier(DelayedAppearance()) }

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

private struct DelayedAppearance: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        // A placeholder without height until then, so the wait has something on screen to run on.
        VStack(spacing: 0) {
            if shown { content.transition(.opacity) } else { Color.clear.frame(height: 0) }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(800))
            withAnimation(.easeOut(duration: 0.25)) { shown = true }
        }
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
                        .tint(Theme.smoke)
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
                SnoozeCustomItems(session: session, actions: actions) { run($0) }
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
                NookPrimaryButton(title: String(localized: "Pair again")) {
                    client.revokedMac = nil
                    client.addingMac = true
                }
                NookGhostButton(title: String(localized: "Not now")) { client.revokedMac = nil }
            }
        }
        if case .offline(let reason) = client.phase {
            // One quiet line: why, and since when what shows is from; a tap explains more. It waits a moment before it
            // shows, so a short drop while the phone wakes or changes networks passes unseen.
            Button { diagnosing = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Image(icon: "wifi.slash")
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(reason.isEmpty ? String(localized: "Looking for your Mac…") : reason)
                        if let updated = client.lastUpdated {
                            Text("Last updated \(updated.formatted(date: .omitted, time: .shortened)) · not connected")
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if let hint = client.awayHint { Text(hint).foregroundStyle(Theme.textTertiary) }
                    }
                    Spacer(minLength: Theme.Spacing.md)
                    Image(icon: "info.circle").foregroundStyle(Theme.textTertiary)
                }
                .font(Theme.TextStyle.detail)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Theme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
            .accessibilityHint(Text("Why can't I connect?"))
            .appearsAfterDelay()
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
        case .ok:
            // Both work together, but one is a version behind the other: what is missing, and which one to update.
            switch client.versionNotice {
            case .macBehind:
                Banner(text: String(localized: "Nook on your Mac is a version behind this app. Update it to use everything the app offers."),
                       symbol: "arrow.down.circle")
            case .phoneBehind:
                Banner(text: String(localized: "This app is a version behind Nook on your Mac. Update it to use everything Nook offers."),
                       symbol: "arrow.down.circle")
            case nil:
                EmptyView()
            }
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
            Image(icon: symbol).foregroundStyle(Theme.textSecondary)
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

/// A session in a list, laid out as a card row the way t3code's iPhone app lists threads, in Nook's colors: the agent's
/// logo where its project's mark would be, the session's name in full strength over up to two lines, and on the right
/// its state (or how long ago); under the name the folder and branch it works in. A row that asks nothing of you
/// recedes, so what needs you is the only loud thing; the logo is grey at rest, as on the Mac.
struct AgentRow: View {
    let session: SessionDigest

    /// Only what needs you is set in full strength; work in progress and the rest read quieter.
    private var receded: Bool { !SessionListView.needsYou(session) }
    private var branch: String? {
        guard let branch = session.branch, !branch.isEmpty, branch != session.folder else { return nil }
        return branch
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md + Theme.Spacing.xxs) {
            AgentMark(agent: session.agent, size: 20, quiet: receded && session.attention != "working")
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                    Text(session.title)
                        .font(Theme.TextStyle.strong)
                        .foregroundStyle(receded ? Theme.textStrong : Theme.paper)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    slot
                }
                meta
            }
        }
        .padding(.horizontal, Theme.Spacing.md + Theme.Spacing.xxs)
        .padding(.vertical, SharedMetrics.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Where it works: the folder, then its branch in the code font, quiet and on one line; the newest words of an
    /// answer instead when the session waits on you without a question to show.
    private var meta: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label {
                Text(session.folder).lineLimit(1)
            } icon: {
                Image(icon: "folder").font(Theme.font(10, .medium))
            }
            .labelStyle(.titleAndIcon)
            .layoutPriority(1)
            if let branch {
                Text(verbatim: "·")
                AgentRowBranch(branch: branch)
                    .font(Theme.TextStyle.code)
            }
            Spacer(minLength: 0)
        }
        .font(Theme.TextStyle.detail)
        .foregroundStyle(Theme.textTertiary)
    }

    /// The status where it says something (working, waiting, failed, ready), otherwise how long ago.
    @ViewBuilder
    private var slot: some View {
        if ["working", "ready"].contains(session.attention) || Theme.needsYou(session.attention) {
            StatusPill(attention: session.attention, short: true)
        } else {
            Text(Self.age(Date().timeIntervalSince1970 - session.updated))
                .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).fixedSize()
        }
    }

    /// Short, as the Mac's lists (`AgentFormat.short`): "now", "12 min", "3 h", "2 d".
    static func age(_ interval: TimeInterval) -> String {
        let minutes = Int(max(0, interval) / 60)
        if minutes < 1 { return String(localized: "now") }
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let hours = minutes / 60
        if hours < 24 { return String(localized: "\(hours) h") }
        return String(localized: "\(hours / 24) d")
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
                    AgentMark(agent: session.agent, size: 16)
                    Text(session.title).font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer(minLength: Theme.Spacing.md)
                    StatusPill(attention: session.attention, short: true)
                }
                .contentShape(Rectangle())
            }

            if let item {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(item.title).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(4)
                    if !item.detail.isEmpty {
                        Text(item.detail).font(Theme.TextStyle.code).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            .padding(Theme.Spacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .roundedBackground(Theme.well, radius: Theme.Radius.control)
                            .roundedStrokeBorder(Theme.hairline, radius: Theme.Radius.control, lineWidth: 0.5)
                    }
                }
                actions(item)
            } else if !session.excerpt.isEmpty {
                Text(session.excerpt).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Theme.color(session.attention).opacity(0.10), Theme.color(session.attention).opacity(0)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)),
            in: Theme.shape(Theme.Radius.panel)
        )
        .cardBackground(Theme.surface, stroke: Theme.color(session.attention).opacity(0.35), radius: Theme.Radius.panel)
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
                    // The same two thumb-sized buttons as on the session's own screen (`DecisionButton`).
                    DecisionButton(title: String(localized: "Deny"), symbol: "xmark", role: .deny) {
                        Haptics.warning(); Task { await client.decide(session, item: item, allow: false) }
                    }
                    DecisionButton(title: String(localized: "Allow"), symbol: "checkmark", role: .allow) {
                        Haptics.success(); Task { await client.decide(session, item: item, allow: true) }
                    }
                } else {
                    NookGhostButton(title: String(localized: "Deny")) {
                        Haptics.warning(); Task { await client.decide(session, item: item, allow: false) }
                    }
                    Label("Only on your Mac: this one is risky or unknown.", systemImage: "lock.fill")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.amber)
                }
            case .question:
                opener {
                    Text("Answer").font(Theme.textFont(14, .semibold)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18)
                        .frame(height: SharedMetrics.buttonHeight)
                        .background(Theme.paper, in: Capsule())
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
