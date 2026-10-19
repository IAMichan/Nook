import SwiftUI
import CoreImage.CIFilterBuiltins

/// Settings for the iPhone companion: switch it on, pair a phone (QR code or link, valid for five minutes) and remove phones.
struct CompanionSettingsRows: View {
    @ObservedObject private var store = CompanionStore.shared
    @ObservedObject private var server = CompanionServer.shared
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
            }
        }
        // The window closes by itself; also when a phone completes it.
        .onChange(of: store.devices) { _, _ in link = nil }
        .onChange(of: store.enabled) { _, on in if !on { link = nil } }
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
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
