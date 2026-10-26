import SwiftUI

/// Antigravity runs in Nook on Google's own ACP server, installed once: the pinned release for this
/// Mac, checked before anything is unpacked. Shown where you start an Antigravity session, and in Settings.
struct AntigravitySetupRow: View {
    @ObservedObject private var installer = AntigravityInstaller.shared
    /// In Settings: also the way back (remove), and a quieter look.
    var inSettings = false
    /// Removing asks first: the release has to be downloaded again to use Antigravity.
    @State private var confirmRemove = false

    var body: some View {
        let installed = installer.installed != nil
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            HStack(spacing: NookTheme.Spacing.md) {
                Text(installed ? tr("ws.antigravity.installed", AntigravityRelease.version) : tr("ws.antigravity.needed",
                     ByteCountFormatter.string(fromByteCount: Int64(AntigravityRelease.current?.archiveBytes ?? 0), countStyle: .file)))
                    .foregroundStyle(installed ? NookTheme.textTertiary : NookTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                switch installer.phase {
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(width: 90)
                    Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(NookTheme.textTertiary)
                case .verifying, .unpacking, .checking:
                    ProgressView().controlSize(.small)
                    Text(phaseText).foregroundStyle(NookTheme.textTertiary)
                case .idle, .failed:
                    if !installed {
                        SmallGhostButton(title: tr("ws.antigravity.install")) { installer.install() }
                    } else if inSettings {
                        SmallGhostButton(title: tr("ws.antigravity.remove")) { confirmRemove = true }
                            .confirmationDialog(tr("confirm.remove", "Antigravity"), isPresented: $confirmRemove,
                                                titleVisibility: .visible) {
                                Button(tr("ws.antigravity.remove"), role: .destructive) { installer.uninstall() }
                                Button(tr("button.cancel"), role: .cancel) {}
                            }
                    }
                }
            }
            if case .failed(let message) = installer.phase {
                Text(message).foregroundStyle(NookTheme.coralSoft).fixedSize(horizontal: false, vertical: true)
            }
            if inSettings || !installed {
                Text(tr("ws.antigravity.note")).foregroundStyle(NookTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(NookTheme.TextStyle.detail)
    }

    private var phaseText: String {
        switch installer.phase {
        case .verifying: return tr("ws.antigravity.verifying")
        case .unpacking: return tr("ws.antigravity.unpacking")
        case .checking: return tr("ws.antigravity.checking")
        default: return ""
        }
    }
}
