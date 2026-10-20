import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

/// Settings for the iPhone companion: switch it on, pair a phone (QR code or link, valid for five minutes) and remove phones.
struct CompanionSettingsRows: View {
    @ObservedObject private var store = CompanionStore.shared
    @ObservedObject private var server = CompanionServer.shared
    @ObservedObject private var notifier = CompanionNotifier.shared
    @State private var keyProblem = false
    @State private var link: PairingLink?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(tr("companion.enable"), isOn: Binding(get: { store.enabled }, set: { store.enabled = $0; server.apply() }))
            Text(tr("companion.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.enabled {
                status
                ForEach(store.devices) { device in
                    HStack {
                        Image(systemName: "iphone").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.lastSeen.map { tr("companion.lastSeen", $0.formatted(.relative(presentation: .named))) }
                                 ?? tr("companion.neverSeen"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(tr("companion.remove")) { store.remove(device.id) }
                    }
                }
                if store.devices.isEmpty { Text(tr("companion.none")).font(.caption).foregroundStyle(.secondary) }
                if let link {
                    pairing(link)
                } else {
                    Button(tr("companion.pair")) { link = server.pairingLink() }
                        .disabled(!isListening)
                }
                Divider()
                pushSection
            }
        }
        // The window closes by itself; also when a phone completes it.
        .onChange(of: store.devices) { _, _ in link = nil }
        .onChange(of: store.enabled) { _, on in if !on { link = nil } }
    }

    // MARK: Push

    private func kindBinding(_ kind: PushEvent.Kind) -> Binding<Bool> {
        Binding(get: { store.push.kinds.contains(kind) },
                set: { on in if on { store.push.kinds.insert(kind) } else { store.push.kinds.remove(kind) } })
    }

    private func hourBinding(_ keyPath: WritableKeyPath<PushSettings, Int?>) -> Binding<Int> {
        Binding(get: { store.push[keyPath: keyPath] ?? 22 }, set: { store.push[keyPath: keyPath] = $0 })
    }

    @ViewBuilder
    private var pushSection: some View {
        Toggle(tr("companion.push.enable"), isOn: $store.push.enabled)
        Text(tr("companion.push.hint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if store.push.enabled {
            Group {
                Toggle(tr("companion.push.approval"), isOn: kindBinding(.approval))
                Toggle(tr("companion.push.question"), isOn: kindBinding(.question))
                Toggle(tr("companion.push.finished"), isOn: kindBinding(.finished))
                Toggle(tr("companion.push.failed"), isOn: kindBinding(.failed))
                Toggle(tr("companion.push.limited"), isOn: kindBinding(.limited))
            }
            .padding(.leading, 12)
            Toggle(tr("companion.push.onlyAway"), isOn: $store.push.onlyWhenAway)
            Toggle(tr("companion.push.titles"), isOn: $store.push.includeTitle)
            Toggle(tr("companion.push.quiet"), isOn: Binding(
                get: { store.push.quietFrom != nil },
                set: { on in store.push.quietFrom = on ? 22 : nil; store.push.quietTo = on ? 7 : nil }))
            if store.push.quietFrom != nil {
                HStack {
                    Stepper(tr("companion.push.from", store.push.quietFrom ?? 22), value: hourBinding(\.quietFrom), in: 0...23)
                    Stepper(tr("companion.push.to", store.push.quietTo ?? 7), value: hourBinding(\.quietTo), in: 0...23)
                }
                Toggle(tr("companion.push.urgent"), isOn: $store.push.quietAllowsUrgent)
            }
            apnsSetup
        }
    }

    @ViewBuilder
    private var apnsSetup: some View {
        Text(tr("companion.push.keyTitle")).font(.headline)
        Text(tr("companion.push.keyHint")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        HStack {
            TextField(tr("companion.push.keyID"), text: $store.apnsKeyID).textFieldStyle(.roundedBorder)
            TextField(tr("companion.push.teamID"), text: $store.apnsTeamID).textFieldStyle(.roundedBorder)
        }
        HStack {
            if store.hasAPNsKey {
                Label(tr("companion.push.keySaved"), systemImage: "checkmark.seal").foregroundStyle(.secondary)
                Button(tr("companion.remove")) { store.removeAPNsKey(); APNsClient.shared.forgetToken(); keyProblem = false }
            } else {
                Button(tr("companion.push.importKey")) { importKey() }
            }
            Button(tr("companion.push.test")) { notifier.sendTest() }
                .disabled(!store.canPush || !store.devices.contains { $0.pushToken != nil })
        }
        if keyProblem { Text(tr("companion.push.keyInvalid")).font(.caption).foregroundStyle(.red) }
        if !store.canPush { Text(tr("companion.push.notReady")).font(.caption).foregroundStyle(.secondary) }
        if let result = notifier.lastResult { Text(result).font(.caption).foregroundStyle(.secondary) }
    }

    /// Reads the .p8 file the user downloaded from Apple; its contents go to the Keychain and are not shown.
    private func importKey() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        keyProblem = !store.saveAPNsKey(pem: text)
        APNsClient.shared.forgetToken()
    }

    private var isListening: Bool { if case .listening = server.state { return true }; return false }

    @ViewBuilder
    private var status: some View {
        switch server.state {
        case .listening(let port): Text(tr("companion.listening", Int(port))).font(.caption).foregroundStyle(.secondary)
        case .failed(let message): Text(tr("companion.failed", message)).font(.caption).foregroundStyle(.red)
        case .stopped: EmptyView()
        }
    }

    private func pairing(_ link: PairingLink) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let url = link.url, let image = Self.qr(url.absoluteString) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 160, height: 160)
                    .accessibilityLabel(tr("companion.qr"))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(tr("companion.pairSteps")).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button(copied ? tr("companion.copied") : tr("companion.copyLink")) {
                    if let url = link.url {
                        Pasteboard.copy(url.absoluteString)
                        copied = true
                    }
                }
                Button(tr("companion.cancelPairing")) { store.cancelPairing(); self.link = nil; copied = false }
            }
        }
    }

    private static func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
