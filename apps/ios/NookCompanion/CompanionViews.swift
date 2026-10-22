import SwiftUI
import VisionKit

struct RootView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.today
    @State private var todayPath: [String] = []
    @State private var sessionPath: [String] = []
    @State private var chatPath: [ChatRoute] = []

    enum Tab { case today, sessions, nook, usage }

    var body: some View {
        Group {
            switch client.phase {
            case .unpaired, .pairing:
                PairingView()
            case .connected, .offline:
                TabView(selection: $tab) {
                    NavigationStack(path: $todayPath) {
                        TodayView(openChat: { prompt in
                            chatPath = [.new(UUID(), prompt)]
                            tab = .nook
                        }, openUsage: { tab = .usage })
                    }
                    .tabItem { Label("Today", systemImage: "house.fill") }
                    .tag(Tab.today)
                    NavigationStack(path: $sessionPath) {
                        SessionListView(path: $sessionPath)
                    }
                    .tabItem { Label("Agents", systemImage: "square.stack.3d.up.fill") }
                    .badge(client.sessions.needingYou)
                    .tag(Tab.sessions)
                    NavigationStack(path: $chatPath) {
                        ChatListView(path: $chatPath)
                    }
                    .tabItem { Label("Chat", systemImage: "sparkles") }
                    .tag(Tab.nook)
                    NavigationStack {
                        UsageScreen()
                    }
                    .tabItem { Label("Usage", systemImage: "chart.bar.fill") }
                    .tag(Tab.usage)
                }
            }
        }
        .tint(Theme.iris)
        .preferredColorScheme(.dark)
        .background(Theme.canvas.ignoresSafeArea())
        .task { client.startPolling() }
        // A tapped notification opens its session.
        .onChange(of: client.openSession) { _, id in
            guard let id else { return }
            tab = .sessions
            sessionPath = [id]
            client.openSession = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { client.startPolling() } else { client.stopPolling() }
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
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.md) {
                    NookMark(size: 76)
                    Text("Nook on your iPhone")
                        .font(.largeTitle.weight(.bold)).foregroundStyle(Theme.text)
                    Text("Follow your agents, approve what they ask, start new work, and chat with Nook.")
                        .font(.callout).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
                }
                .padding(.top, 56)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    PairingStep(number: 1, text: "On your Mac, open Nook › Settings › iPhone companion and turn it on.")
                    PairingStep(number: 2, text: "Choose ‘Pair an iPhone’: Nook shows a code for five minutes.")
                    PairingStep(number: 3, text: "Scan it here. Your phone and Mac need to be on the same Wi‑Fi.")
                }
                .card()

                VStack(spacing: Theme.Spacing.md) {
                    if client.phase == .pairing {
                        ProgressView().controlSize(.large).frame(minHeight: 50)
                    } else if DataScannerViewController.isSupported {
                        Button { scanning = true } label: { Label("Scan the code", systemImage: "qrcode.viewfinder") }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    if pasting || !DataScannerViewController.isSupported {
                        VStack(spacing: Theme.Spacing.sm) {
                            TextField("nook://pair?…", text: $text, axis: .vertical)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...4)
                                .font(.callout.monospaced())
                                .padding(Theme.Spacing.md)
                                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            Button("Pair") { client.pair(link: text) }
                                .buttonStyle(ActionButtonStyle(color: Theme.iris, filled: true))
                                .disabled(text.isEmpty || client.phase == .pairing)
                        }
                        .card(padding: Theme.Spacing.md)
                    } else {
                        Button("Paste the link instead") { withAnimation { pasting = true } }
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
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
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text(number, format: .number)
                .font(.subheadline.weight(.bold)).foregroundStyle(Theme.iris)
                .frame(width: 28, height: 28)
                .background(Theme.iris.opacity(0.15), in: Circle())
            Text(text).font(.callout).foregroundStyle(Theme.text).frame(maxWidth: .infinity, alignment: .leading)
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

/// Everything on the Mac at a glance: a connection line, three counts, then the sessions grouped by what they need:
/// you first, then what is working, then the rest.
struct SessionListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [String]
    @State private var composing = false

    private var ordered: [SessionDigest] { client.sessions.sorted { $0.updated > $1.updated } }
    private var needsYou: [SessionDigest] { ordered.filter(Self.needsYou) }
    private var working: [SessionDigest] { ordered.filter { !Self.needsYou($0) && $0.attention == "working" } }
    private var rest: [SessionDigest] { ordered.filter { !Self.needsYou($0) && $0.attention != "working" } }

    static func needsYou(_ session: SessionDigest) -> Bool {
        !session.items.isEmpty || ["approval", "input", "failed", "limited"].contains(session.attention)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ConnectionLine()
                if client.macPushReady == false {
                    Banner(text: String(localized: "Push notifications are not ready on your Mac yet (Settings › iPhone companion)."),
                           symbol: "bell.slash.fill", color: Theme.textSecondary)
                }
                if !client.sessions.isEmpty {
                    HStack(spacing: Theme.Spacing.sm) {
                        OverviewTile(count: needsYou.count, title: "Needs you", symbol: "hand.raised.fill", color: Theme.amber, highlight: true)
                        OverviewTile(count: working.count, title: "Working", symbol: "bolt.fill", color: Theme.iris)
                        OverviewTile(count: rest.count, title: "Done", symbol: "checkmark", color: Theme.mint)
                    }
                }
                group("Needs you", needsYou, color: Theme.amber)
                group("Working", working, color: Theme.iris)
                group("Recent", rest, color: Theme.textTertiary)
                if client.sessions.isEmpty, client.phase == .connected {
                    EmptyState(symbol: "square.stack.3d.up", title: "No sessions",
                               message: "Sessions of your coding agents on your Mac show up here.") {
                        if client.can(CompanionFeature.start) {
                            Button { composing = true } label: { Label("New session", systemImage: "plus") }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .refreshable { await client.refresh() }
        .navigationTitle("Agents")
        .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Unpair from this Mac", role: .destructive) { client.unpair() }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(Theme.textSecondary) }
            }
            if client.can(CompanionFeature.start) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { composing = true } label: {
                        Image(systemName: "plus").font(.body.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 32, height: 32).background(Theme.iris, in: Circle())
                    }
                    .accessibilityLabel("New session")
                }
            }
        }
        .sheet(isPresented: $composing) {
            NewSessionView { id in path.append(id) }
        }
        .screen()
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ sessions: [SessionDigest], color: Color) -> some View {
        if !sessions.isEmpty {
            SectionHeader(title: title, count: sessions.count, color: color)
            ForEach(sessions) { SessionCard(session: $0) }
        }
    }
}

/// Which Mac this is and whether it answers.
struct ConnectionLine: View {
    @EnvironmentObject private var client: CompanionClient

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            switch client.phase {
            case .offline(let reason):
                Image(systemName: "wifi.slash").foregroundStyle(Theme.amber)
                Text(reason.isEmpty ? String(localized: "Looking for your Mac…") : reason)
                    .foregroundStyle(Theme.amber).lineLimit(2)
            default:
                Circle().fill(Theme.mint).frame(width: 8, height: 8)
                Image(systemName: "laptopcomputer").foregroundStyle(Theme.textSecondary)
                Text(client.macName.isEmpty ? "Mac" : client.macName).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, Theme.Spacing.xs)
    }
}

struct OverviewTile: View {
    let count: Int
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    /// Tinted while the count is not zero: for what waits on you.
    var highlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: symbol).font(.footnote.weight(.semibold)).foregroundStyle(count > 0 ? color : Theme.textTertiary)
            Text(count, format: .number)
                .font(.title2.weight(.bold)).monospacedDigit()
                .foregroundStyle(count > 0 ? Theme.text : Theme.textTertiary)
                .contentTransition(.numericText())
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .card(padding: Theme.Spacing.md, tint: highlight && count > 0 ? color : nil)
        .accessibilityElement(children: .combine)
    }
}

/// A session on the list: open it by tapping the top; what waits on you is answered right on the card.
struct SessionCard: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            NavigationLink(value: session.id) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    AgentIcon(agent: session.agent)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(session.title).font(.headline).foregroundStyle(Theme.text).lineLimit(2)
                            Spacer(minLength: Theme.Spacing.sm)
                            Text(Date(timeIntervalSince1970: session.updated), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                                .font(.caption2).foregroundStyle(Theme.textTertiary)
                        }
                        Text(meta).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        StatusPill(attention: session.attention).padding(.top, 2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let item = session.items.first {
                WaitingItem(session: session, item: item, more: session.items.count - 1)
            } else if !session.excerpt.isEmpty {
                Text(session.excerpt)
                    .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(3)
                    .padding(.leading, 36 + Theme.Spacing.md)
            }
        }
        .card(tint: session.items.isEmpty ? nil : Theme.amber)
    }

    private var meta: String {
        [session.agent, session.folder, session.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The first thing that waits in a session, with its buttons: allow or deny an approval, or go answer a question.
private struct WaitingItem: View {
    @EnvironmentObject private var client: CompanionClient
    let session: SessionDigest
    let item: SessionDigest.Item
    let more: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(item.title).font(.subheadline).foregroundStyle(Theme.text).lineLimit(3)
            if !item.detail.isEmpty {
                Text(item.detail).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            switch item.kind {
            case .approval:
                HStack(spacing: Theme.Spacing.sm) {
                    Button("Deny") { Haptics.warning(); Task { await client.decide(session, item: item, allow: false) } }
                        .buttonStyle(ActionButtonStyle(color: Theme.coral))
                    if item.canAllow {
                        Button("Allow") { Haptics.success(); Task { await client.decide(session, item: item, allow: true) } }
                            .buttonStyle(ActionButtonStyle(color: Theme.mint, filled: true))
                    }
                }
                if !item.canAllow {
                    Label("Only on your Mac: this one is risky or unknown.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(Theme.amber)
                }
            case .question:
                NavigationLink(value: session.id) { Text("Answer") }
                    .buttonStyle(ActionButtonStyle(color: Theme.amber, filled: true))
            }
            if more > 0 {
                Text("and \(more) more").font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
