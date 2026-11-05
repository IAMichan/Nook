import SwiftUI

/// The Android devices under the Simulator page: nothing without the Android SDK. A running one shows its screen, refreshed
/// about once a second while the page is open.
struct AndroidDevicesView: View {
    @State private var devices: [AndroidDevice] = []
    @State private var chosen: String?
    @State private var picture: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.md) {
            if !devices.isEmpty {
                Text(tr("sim.android.title")).font(NookTheme.TextStyle.label).foregroundStyle(NookTheme.textTertiary)
                ForEach(devices) { device in
                    HStack(spacing: NookTheme.Spacing.md) {
                        Text(device.name).font(NookTheme.TextStyle.detail).foregroundStyle(NookTheme.textSecondary).lineLimit(1)
                        Spacer(minLength: 8)
                        if device.running {
                            Button(tr("sim.android.show")) { chosen = device.serial }.controlSize(.small)
                        } else {
                            Button(tr("sim.android.start")) {
                                try? AndroidDevices.boot(avd: String(device.id.dropFirst(AndroidDevices.idPrefix.count + 5)))
                            }.controlSize(.small)
                        }
                    }
                }
                if let picture {
                    Image(nsImage: picture).resizable().scaledToFit().frame(maxHeight: 420)
                        .accessibilityLabel(tr("sim.android.screen"))
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let serial = chosen
                let found = await Task.detached(priority: .utility) { () -> ([AndroidDevice], Data?) in
                    (AndroidDevices.all(), serial.flatMap(AndroidDevices.screenshot))
                }.value
                if found.0 != devices { devices = found.0 }
                if let data = found.1 { picture = NSImage(data: data) }
                try? await Task.sleep(nanoseconds: (chosen == nil ? 5 : 1) * 1_000_000_000)
            }
        }
    }
}
