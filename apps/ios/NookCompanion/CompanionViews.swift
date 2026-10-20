import SwiftUI
import VisionKit

struct RootView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.sessions
    @State private var sessionPath: [String] = []
    @State private var chatPath: [ChatRoute] = []

    enum Tab { case sessions, nook }

    var body: some View {
        Group {
            switch client.phase {
            case .unpaired, .pairing:
                NavigationStack { PairingView().navigationTitle("Nook") }
            case .connected, .offline:
                TabView(selection: $tab) {
                    NavigationStack(path: $sessionPath) {
                        SessionListView(path: $sessionPath)
                            .navigationTitle(client.macName.isEmpty ? "Nook" : client.macName)
                    }
                    .tabItem { Label("Sessions", systemImage: "terminal") }
                    .badge(client.sessions.needingYou)
                    .tag(Tab.sessions)
                    NavigationStack(path: $chatPath) {
                        ChatListView(path: $chatPath)
                            .navigationTitle("Nook")
                    }
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    .tag(Tab.nook)
                }
            }
        }
        .tint(Palette.iris)
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

enum Palette {
    static let iris = Color(red: 0.55, green: 0.5, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.3)
    static let coral = Color(red: 1.0, green: 0.42, blue: 0.42)
    static let mint = Color(red: 0.27, green: 0.88, blue: 0.65)

    static func color(_ attention: String) -> Color {
        switch attention {
        case "approval", "input": return amber
        case "failed": return coral
        case "limited": return amber
        case "working": return iris
        case "ready": return mint
        default: return .secondary
        }
    }

    static func word(_ attention: String) -> String {
        switch attention {
        case "approval": return String(localized: "Waiting for approval")
        case "input": return String(localized: "Has a question")
        case "failed": return String(localized: "Failed")
        case "limited": return String(localized: "Limit reached")
        case "working": return String(localized: "Working")
        case "ready": return String(localized: "Ready")
        case "finished": return String(localized: "Finished")
        default: return String(localized: "Idle")
        }
    }
}

// MARK: Pairing

struct PairingView: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var text = ""
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                Text("On your Mac, turn on the iPhone companion in Nook › Settings and choose ‘Pair an iPhone’. Then scan the code, or paste the link. Your phone and Mac must be on the same Wi‑Fi.")
                    .font(.callout)
            }
            Section {
                if DataScannerViewController.isSupported {
                    Button { scanning = true } label: { Label("Scan the code", systemImage: "qrcode.viewfinder") }
                }
                TextField("nook://pair?…", text: $text, axis: .vertical)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().lineLimit(1...4)
                Button("Pair") { client.pair(link: text) }
                    .disabled(text.isEmpty || client.phase == .pairing)
                if client.phase == .pairing { ProgressView() }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { value in
                scanning = false
                client.pair(link: value)
            }
            .ignoresSafeArea()
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

struct SessionListView: View {
    @EnvironmentObject private var client: CompanionClient
    @Binding var path: [String]
    @State private var composing = false

    private var sorted: [SessionDigest] {
        let rank = ["approval": 0, "input": 1, "failed": 2, "limited": 3, "working": 4, "ready": 5, "idle": 6, "finished": 7]
        return client.sessions.sorted {
            let (a, b) = (rank[$0.attention] ?? 9, rank[$1.attention] ?? 9)
            return a != b ? a < b : $0.updated > $1.updated
        }
    }

    var body: some View {
        List {
            if case .offline(let reason) = client.phase {
                Label(reason.isEmpty ? String(localized: "Looking for your Mac…") : reason, systemImage: "wifi.slash").foregroundStyle(Palette.amber)
            }
            if client.macPushReady == false {
                Label("Push notifications are not ready on your Mac yet (Settings › iPhone companion).", systemImage: "bell.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(sorted) { session in
                NavigationLink(value: session.id) { SessionRow(session: session) }
                    // The first thing that waits, one swipe away: deny always, allow when the Mac says it is low risk.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if let item = session.items.first(where: { $0.kind == .approval }) {
                            Button("Deny", role: .destructive) { Task { await client.decide(session, item: item, allow: false) } }
                            if item.canAllow {
                                Button("Allow") { Task { await client.decide(session, item: item, allow: true) } }.tint(Palette.mint)
                            }
                        }
                    }
            }
            if client.sessions.isEmpty, client.phase == .connected {
                Group {
                    if client.can(CompanionFeature.start) { Text("No sessions. Start one with +.") } else { Text("No sessions.") }
                }
                .foregroundStyle(.secondary)
            }
        }
        .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
        .refreshable { await client.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if client.can(CompanionFeature.start) {
                    Button { composing = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New session")
                }
                Menu {
                    Button("Unpair from this Mac", role: .destructive) { client.unpair() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $composing) {
            NewSessionView { id in path.append(id) }
        }
    }
}

struct SessionRow: View {
    let session: SessionDigest

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(Palette.color(session.attention)).frame(width: 9, height: 9)
                Text(session.title).font(.headline).lineLimit(1)
            }
            Text("\(Palette.word(session.attention)) · \(session.agent) · \(session.folder)")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !session.items.isEmpty {
                Text(session.items[0].title).font(.subheadline).foregroundStyle(Palette.amber).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
