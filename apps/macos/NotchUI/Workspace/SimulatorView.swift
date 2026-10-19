import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The simulator without the device tools (no Node.js, or not installed yet): its screen as a picture from
/// `simctl io screenshot`, refreshed about once a second while the page is open, to copy or save.
struct SimulatorSnapshotView: View {
    @State private var devices: [SimulatorDevice] = []
    @State private var chosen: String?
    @State private var image: NSImage?
    @State private var png: Data?
    @State private var looked = false
    /// Simulator.app wherever Xcode is; nil without Xcode.
    private let simulatorApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if devices.count > 1 {
                    Picker("", selection: Binding<String?>(get: { chosen }, set: { chosen = $0; image = nil })) {
                        ForEach(devices) { Text("\($0.name) · \($0.runtime)").tag(Optional($0.udid)) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                } else if let device = devices.first {
                    Text("\(device.name) · \(device.runtime)").font(NookTheme.font(12.5, .medium)).foregroundStyle(NookTheme.textSecondary)
                }
                Spacer()
                if png != nil {
                    Button(tr("sim.copy")) { copy() }.controlSize(.small)
                    Button(tr("sim.save")) { save() }.controlSize(.small)
                }
                if let simulatorApp {
                    Button(tr("sim.openApp")) {
                        NSWorkspace.shared.openApplication(at: simulatorApp, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                    }
                    .controlSize(.small)
                }
            }
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if devices.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone").font(.system(size: 28)).foregroundStyle(NookTheme.textTertiary)
                        Text(looked ? tr("sim.none") : tr("sim.looking"))
                            .font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task { await loop() }
    }

    /// The device list every few seconds, the screen about once a second; stops when the page closes.
    private func loop() async {
        var listed = Date.distantPast
        // Each screenshot is a process and a PNG written and read back. About once a second while the screen changes;
        // up to every three seconds while it stays the same (an idle app), back to fast as soon as it changes.
        var wait: UInt64 = 1_200_000_000
        while !Task.isCancelled {
            // The device list about every six seconds, whatever the screenshot pace.
            if Date().timeIntervalSince(listed) >= 6 {
                listed = Date()
                let found = await Task.detached(priority: .utility) { Simulators.booted() }.value
                devices = found
                looked = true
                if chosen == nil || !found.contains(where: { $0.udid == chosen }) { chosen = found.first?.udid; image = nil; png = nil }
            }
            if let udid = chosen {
                let data = await Task.detached(priority: .utility) { Simulators.screenshot(udid) }.value
                if let data, data == png {
                    wait = min(wait + 600_000_000, 3_000_000_000)
                } else {
                    wait = 1_200_000_000
                    if let data, udid == chosen, let picture = NSImage(data: data) {
                        png = data
                        image = picture
                    }
                }
            }
            try? await Task.sleep(nanoseconds: wait)
        }
    }

    private func copy() {
        guard let png else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setData(png, forType: .png)
    }

    private func save() {
        guard let png else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Simulator.png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}
