import SwiftUI
import VisionKit

struct RootView: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                switch client.phase {
                case .unpaired, .pairing: PairingView()
                case .connected, .offline: SessionListView()
                }
            }
            .navigationTitle(client.macName.isEmpty ? "Nook" : client.macName)
        }
        .tint(Palette.iris)
        .task { client.startPolling() }
        // A tapped notification opens its session.
        .onChange(of: client.openSession) { _, id in
            guard let id else { return }
            path = [id]
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
                Text("No sessions.").foregroundStyle(.secondary)
            }
        }
        .navigationDestination(for: String.self) { id in SessionDetailView(sessionID: id) }
        .refreshable { await client.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Unpair from this Mac", role: .destructive) { client.unpair() }
                } label: { Image(systemName: "ellipsis.circle") }
            }
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

struct SessionDetailView: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    @State private var message = ""
    @State private var confirmStop = false

    private var session: SessionDigest? { client.sessions.first { $0.id == sessionID } }

    var body: some View {
        if let session {
            List {
                Section {
                    Label(Palette.word(session.attention), systemImage: "circle.fill").foregroundStyle(Palette.color(session.attention))
                    Text("\(session.agent) · \(session.folder)\(session.branch.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(session.items) { item in
                    Section(Self.sectionTitle(for: item)) {
                        ItemView(session: session, item: item)
                    }
                }
                if !session.excerpt.isEmpty {
                    Section("Latest reply") { Text(session.excerpt).font(.callout) }
                }
                if session.canSend != false {
                    Section("Send a message") {
                        TextField("Message to the agent", text: $message, axis: .vertical).lineLimit(1...5)
                        Button("Send") {
                            let text = message
                            message = ""
                            Task { await client.send(session, text: text) }
                        }
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if session.attention == "working" || session.attention == "approval" || session.attention == "input" {
                        Section {
                            Button("Stop", role: .destructive) { confirmStop = true }
                        }
                    }
                } else {
                    Section {
                        Text("This agent runs in a terminal on your Mac; answer it there.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(session.title)
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Stop this session?", isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop the session", role: .destructive) { Task { await client.stop(session) } }
            }
        } else {
            Text("This session is gone.").foregroundStyle(.secondary)
        }
    }

    /// The heading above an item: typed, so both texts go through the String Catalog.
    private static func sectionTitle(for item: SessionDigest.Item) -> LocalizedStringKey {
        item.kind == .approval ? "Approval" : "Question"
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
