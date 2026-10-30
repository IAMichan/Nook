import SwiftUI

/// "Why can't I connect?": every route to the Mac checked once more, what stands in the way, each hop on the way, and
/// what to do (`CompanionDiagnosis`, docs/COMPANION.md › When it does not connect).
struct DiagnosisSheet: View {
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.dismiss) private var dismiss
    @State private var result: CompanionDiagnosis.Result?
    @State private var checking = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if let result {
                        Text(DiagnosisText.headline(result.cause, mac: macName))
                            .font(Theme.TextStyle.heading).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        if let ms = result.fastestMilliseconds {
                            Text("Answered in \(ms) ms").font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
                        }
                        RowGroup {
                            ForEach(Array(result.hops.enumerated()), id: \.offset) { index, state in
                                if index > 0 { RowSeparator(inset: Theme.Spacing.xxxl + Theme.Spacing.md) }
                                HopRow(state: state, mac: macName)
                            }
                        }
                        if !result.steps.isEmpty {
                            SectionHeader(title: "What to do")
                            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                                ForEach(Array(result.steps.enumerated()), id: \.offset) { index, step in
                                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                                        Text(index + 1, format: .number)
                                            .font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary).monospacedDigit()
                                        Text(DiagnosisText.step(step, mac: macName))
                                            .font(Theme.TextStyle.body).foregroundStyle(Theme.textStrong)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .card()
                        }
                    } else {
                        ProgressView().controlSize(.large).frame(maxWidth: .infinity, minHeight: 160)
                        Text("Checking every way to reach your Mac…")
                            .font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
                    }
                    Button { Task { await check() } } label: { Label("Check again", systemImage: "arrow.clockwise") }
                        .buttonStyle(ActionButtonStyle())
                        .disabled(checking)
                    // The local connection log, without addresses, names or keys; nothing is sent anywhere.
                    Button {
                        UIPasteboard.general.string = client.diagnosticsBundle()
                        copied = true
                        Haptics.success()
                    } label: { Label(copied ? LocalizedStringKey("Copied") : LocalizedStringKey("Copy diagnostics"), systemImage: copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(ActionButtonStyle())
                    Text("Diagnostics stay on this iPhone until you paste them somewhere; addresses, names and keys are left out.")
                        .font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                }
                .padding(Theme.Spacing.xl)
            }
            .screen()
            .navigationTitle("Why can't I connect?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.foregroundStyle(Theme.text) }
            }
            .task { await check() }
        }
        .preferredColorScheme(.dark)
        .tint(Theme.text)
    }

    private var macName: String { client.macName.isEmpty ? String(localized: "your Mac") : client.macName }

    private func check() async {
        guard !checking else { return }
        checking = true
        result = nil
        result = await client.diagnose()
        checking = false
    }
}

private struct HopRow: View {
    let state: CompanionDiagnosis.HopState
    let mac: String

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: Theme.Spacing.xxl)
            Text(DiagnosisText.hop(state.hop, mac: mac)).font(Theme.TextStyle.body).foregroundStyle(Theme.textStrong)
            Spacer(minLength: Theme.Spacing.md)
            Text(DiagnosisText.result(state.result)).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state.result {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .unchecked: return "circle.dashed"
        }
    }

    private var color: Color {
        switch state.result {
        case .ok: return Theme.mint
        case .failed: return Theme.coral
        case .unchecked: return Theme.textTertiary
        }
    }
}

/// The words for what `CompanionDiagnosis` found.
enum DiagnosisText {
    static func headline(_ cause: CompanionDiagnosis.Cause, mac: String) -> String {
        switch cause {
        case .connected: return String(localized: "\(mac) answers: the connection works.")
        case .deviceOffline: return String(localized: "This iPhone is offline.")
        case .macTooOld: return String(localized: "Nook on \(mac) is too old for this app.")
        case .phoneTooOld: return String(localized: "This app is too old for Nook on \(mac).")
        case .clockSkew: return String(localized: "The clocks of this iPhone and \(mac) are too far apart.")
        case .rateLimited: return String(localized: "\(mac) asks this iPhone to slow down.")
        case .notPaired: return String(localized: "\(mac) does not know this iPhone any more.")
        case .keyMismatch: return String(localized: "Something else answers at the address of \(mac).")
        case .macNotOnRelay: return String(localized: "The relay works, but \(mac) is not connected to it.")
        case .relayFull: return String(localized: "The relay has too many connections for \(mac) right now.")
        case .relayUnreachable: return String(localized: "This iPhone cannot reach the relay.")
        case .tailnetSilent: return String(localized: "\(mac) does not answer over Tailscale.")
        case .notOnLocalNetwork: return String(localized: "\(mac) does not answer on this network.")
        case .macSilent: return String(localized: "\(mac) was reached but did not answer in time.")
        case .notChecked: return String(localized: "Nothing was checked yet.")
        }
    }

    static func hop(_ hop: CompanionDiagnosis.Hop, mac: String) -> String {
        switch hop {
        case .device: return String(localized: "This iPhone")
        case .localNetwork: return String(localized: "Local network")
        case .tailnet: return String(localized: "Tailscale")
        case .relay: return String(localized: "Relay")
        case .mac: return String(localized: "Nook on \(mac)")
        }
    }

    static func result(_ result: CompanionDiagnosis.HopResult) -> String {
        switch result {
        case .ok: return String(localized: "Works")
        case .failed: return String(localized: "Failed")
        case .unchecked: return String(localized: "Not checked")
        }
    }

    static func step(_ step: CompanionDiagnosis.Step, mac: String) -> String {
        switch step {
        case .connectDevice: return String(localized: "Connect this iPhone to Wi‑Fi or mobile data. Nook Companion connects again by itself.")
        case .updateMac: return String(localized: "Update Nook on \(mac).")
        case .updateApp: return String(localized: "Update Nook Companion from the App Store.")
        case .setClocks: return String(localized: "Turn on automatic date and time on this iPhone and on \(mac).")
        case .waitAMinute: return String(localized: "Wait a minute; Nook Companion tries again by itself.")
        case .pairAgain: return String(localized: "On \(mac), open Nook › Settings › Connections › iPhone, choose ‘Pair an iPhone’ and scan the code again.")
        case .wakeMac: return String(localized: "Make sure \(mac) is on and awake.")
        case .openNookOnMac: return String(localized: "Make sure Nook runs on \(mac) with iPhone Companion turned on.")
        case .checkRelayOnMac: return String(localized: "On \(mac), check Settings › Connections › iPhone › Away from home: ‘Test relay’ shows whether the relay works.")
        case .keepMacAwake: return String(localized: "Choose ‘Keep this Mac awake’ in the same place, so it stays reachable while you are away.")
        case .checkInternet: return String(localized: "Check that this iPhone has internet; a VPN or content filter can block the relay.")
        case .turnOnTailscale: return String(localized: "Turn on Tailscale on this iPhone and on \(mac), signed in to the same account.")
        case .sameWiFi: return String(localized: "Join the same Wi‑Fi as \(mac).")
        case .setUpAway: return String(localized: "To reach \(mac) away from home, set up Tailscale or the relay in Nook › Settings › Connections › iPhone.")
        }
    }
}
