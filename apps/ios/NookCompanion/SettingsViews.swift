import SwiftUI

// Settings on the phone, the last tab along the bottom, laid out as t3code's iPhone settings: grouped cards of rows,
// each with its icon. What the phone knows about the Mac and how it reaches it, what it does on this iPhone, the plan
// limits the Mac reports, pairing, and the app. What Nook does is still set on the Mac (Settings there is the one place
// for Nook's own configuration); these are the phone's own choices and views.

struct SettingsView: View {
    @EnvironmentObject private var client: CompanionClient
    @ObservedObject private var live = LiveActivities.shared
    @AppStorage("nook.companion.steerByDefault") private var steerByDefault = false
    @State private var diagnosing = false
    @State private var confirmUnpair = false
    @State private var usage: UsageDigest?

    private var macName: String { client.macName.isEmpty ? String(localized: "Your Mac") : client.macName }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                PanelHeader()
                    .padding(.horizontal, -Theme.Spacing.xl)
                ConnectionLine()

                SettingsGroup(title: String(localized: "Your Mac")) {
                    SettingsRow(symbol: "laptopcomputer", title: macName, detail: connectionDetail) {
                        Circle().fill(client.phase == .connected ? Theme.mint : Theme.amber).frame(width: 8, height: 8)
                    }
                    if client.macs.count > 1 {
                        ForEach(client.macs.filter { $0.id != client.activeMacID }) { mac in
                            SettingsButtonRow(symbol: "arrow.left.arrow.right", title: String(localized: "Switch to \(mac.name)")) {
                                client.switchMac(to: mac.id)
                            }
                        }
                    }
                    SettingsButtonRow(symbol: "stethoscope", title: String(localized: "Check the connection")) { diagnosing = true }
                    if client.can(CompanionFeature.requestUpdate) {
                        SettingsButtonRow(symbol: "arrow.down.circle", title: String(localized: "Show the update on your Mac")) {
                            Task { await client.requestMacUpdate() }
                        }
                    }
                }

                SettingsGroup(title: String(localized: "On this iPhone")) {
                    if client.can(CompanionFeature.liveActivity) {
                        SettingsToggleRow(symbol: "platter.filled.top.iphone", title: String(localized: "Live Activities"),
                                          isOn: $live.enabled)
                            .disabled(!live.allowedBySystem)
                    }
                    if client.can(CompanionFeature.steer) {
                        SettingsToggleRow(symbol: "arrow.turn.down.right", title: String(localized: "Steer a working agent right away"),
                                          detail: String(localized: "Off: your message waits until the turn ends."),
                                          isOn: $steerByDefault)
                    }
                    SettingsRow(symbol: client.macPushReady == false ? "bell.slash" : "bell.badge",
                                title: String(localized: "Notifications"),
                                detail: client.macPushReady == false
                                    ? String(localized: "Not set up on your Mac yet (Settings › iPhone companion).")
                                    : String(localized: "From your Mac, also away from home."))
                }

                if client.can(CompanionFeature.usage), client.allows(.read) {
                    SettingsGroup(title: String(localized: "Usage")) {
                        if let usage {
                            if usage.accounts.isEmpty {
                                SettingsRow(symbol: "chart.bar", title: String(localized: "No plan limits reported"))
                            }
                            ForEach(usage.accounts) { account in UsageAccountRow(account: account) }
                            SettingsRow(symbol: "square.stack.3d.up",
                                        title: String(localized: "\(usage.sessions) sessions today"),
                                        detail: String(localized: "\(usage.completed) done · \(usage.running) working · \(usage.failed) failed"))
                        } else {
                            SettingsRow(symbol: "chart.bar", title: String(localized: "Loading…"))
                        }
                    }
                }

                SettingsGroup(title: String(localized: "Pairing")) {
                    SettingsButtonRow(symbol: "plus", title: String(localized: "Pair another Mac")) { client.addingMac = true }
                    SettingsButtonRow(symbol: "xmark.circle", title: String(localized: "Unpair from this Mac"), destructive: true) {
                        confirmUnpair = true
                    }
                }

                SettingsGroup(title: String(localized: "About")) {
                    SettingsRow(symbol: "info.circle", title: String(localized: "Nook Companion"), detail: appVersion)
                    if let mac = client.macAppVersion {
                        SettingsRow(symbol: "laptopcomputer", title: String(localized: "Nook on your Mac"), detail: mac)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxxl)
        }
        .refreshable { usage = await client.loadUsage() }
        .toolbar(.hidden, for: .navigationBar)
        .screen()
        .task { usage = await client.loadUsage() }
        .sheet(isPresented: $diagnosing) { DiagnosisSheet() }
        .confirmationDialog("Unpair from this Mac?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { client.unpair() }
        } message: {
            Text("You can pair again with the code in Nook on your Mac.")
        }
    }

    /// How the phone reaches the Mac now, or since when it does not.
    private var connectionDetail: String {
        switch client.phase {
        case .connected:
            return client.activeRoute.map(RouteText.connected) ?? String(localized: "Connected")
        case .offline:
            if let at = client.lastUpdated {
                return String(localized: "Not connected · last updated \(at.formatted(date: .omitted, time: .shortened))")
            }
            return String(localized: "Not connected")
        default:
            return ""
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }
}

extension CompanionClient {
    /// What the sessions used today and the plan limits of every account (`CompanionOp.usage`); nil when the Mac cannot say.
    func loadUsage() async -> UsageDigest? {
        guard phase == .connected, can(CompanionFeature.usage), allows(.read) else { return nil }
        return await perform(CompanionRequest(op: .usage, item: "today"), quiet: true)?.usage
    }
}

// MARK: Parts

/// A group of settings: its name above, the rows on one rounded card.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.TextStyle.label)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, Theme.Spacing.lg)
            VStack(spacing: 0) { content }
            .roundedBackground(Theme.surface, radius: Theme.Radius.conversationCard)
        }
    }
}

/// A row with an icon, a title, a quieter line under it, and something on the right.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var tint: Color = Theme.textSecondary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            HomeLogo(content: .symbol(symbol), tint: tint, size: 28)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title).font(Theme.TextStyle.body).foregroundStyle(tint == Theme.coral ? Theme.coral : Theme.paper)
                if let detail, !detail.isEmpty {
                    Text(detail).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SettingsRow where Trailing == EmptyView {
    init(symbol: String, title: String, detail: String? = nil, tint: Color = Theme.textSecondary) {
        self.init(symbol: symbol, title: title, detail: detail, tint: tint) { EmptyView() }
    }
}

/// A row that does something when tapped: a chevron on the right, or the title in coral when it removes something.
struct SettingsButtonRow: View {
    let symbol: String
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            SettingsRow(symbol: symbol, title: title, tint: destructive ? Theme.coral : Theme.textSecondary) {
                if !destructive {
                    Image(icon: "chevron.right").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .buttonStyle(RowPress(radius: 0))
    }
}

/// A row with a switch.
struct SettingsToggleRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(symbol: symbol, title: title, detail: detail) {
            Toggle("", isOn: $isOn).labelsHidden().tint(Theme.mint)
        }
    }
}

/// One account's plan limits: each as a bar filling up, amber from 80 percent, with when it resets.
private struct UsageAccountRow: View {
    let account: UsageDigest.Account

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            HomeLogo(content: .agent(account.agent), size: 28)
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text(account.account.isEmpty ? account.agent : "\(account.agent) · \(account.account)")
                    .font(Theme.TextStyle.body).foregroundStyle(Theme.paper)
                ForEach(account.limits) { limit in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack {
                            Text(limit.label)
                            Spacer()
                            Text("\(Int(limit.percent.rounded()))%").monospacedDigit()
                        }
                        .font(Theme.TextStyle.detail)
                        .foregroundStyle(Theme.textSecondary)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.well)
                                Capsule().fill(limit.percent >= 80 ? Theme.amber : Theme.iris)
                                    .frame(width: proxy.size.width * min(1, max(0, limit.percent / 100)))
                            }
                        }
                        .frame(height: 6)
                        if let note = limit.note, !note.isEmpty {
                            Text(note).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        } else if let resets = limit.resetsAt {
                            Text("Resets \(Date(timeIntervalSince1970: resets), format: .relative(presentation: .named))")
                                .font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
    }
}
