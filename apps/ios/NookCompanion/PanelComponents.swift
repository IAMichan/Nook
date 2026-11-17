import SwiftUI

// The phone's panel: its header, tabs, search field, composer and starters, drawn as the Mac's (docs/UI-COMPONENTS.md)
// with touch instead of hover (a press lights what the pointer lights on the Mac) and room for a finger. The buttons,
// badges, list parts and agent logos are not here: both apps compile those from apps/macos/UI/Shared.

// MARK: Logos

/// The icon in front of a row or a starter, the Mac's `HomeLogo`: always a box of the same size, so the text beside it
/// lines up. An agent's logo or a real icon on a neutral tile; a symbol on a tile tinted with its color.
struct HomeLogo: View {
    enum Content {
        case agent(String)
        case symbol(String)
    }

    let content: Content
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 34

    var body: some View {
        Group {
            switch content {
            case .agent(let name): AgentLogo(agent: name, size: size * 0.56)
            case .symbol(let name): Image(icon: name).font(Theme.font(size * 0.42, .medium)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .roundedBackground(tileFill, radius: size * 0.28)
        .accessibilityHidden(true)
    }

    private var tileFill: Color {
        switch content {
        case .agent: return Theme.paper.opacity(0.05)
        case .symbol: return tint.opacity(0.12)
        }
    }
}

// MARK: Headers

/// Nook's sections, in the Mac's order: Nook, Agents and Chats along the bottom of the phone, as the Mac's tab bar;
/// pull requests and Settings open from the header as a sheet, as they open from the Mac's footer. On an iPad with room
/// all five are the sidebar's sections (`CompanionSplitView`).
enum CompanionTab: Hashable, CaseIterable, Identifiable {
    case nook, agents, chats, pulls, settings

    var id: Self { self }

    /// Along the bottom of the phone; the others open from the header (`TabRouter.sheet`).
    var isBarTab: Bool { self == .nook || self == .agents || self == .chats }

    var title: LocalizedStringKey {
        switch self {
        case .nook: return "Nook"
        case .agents: return "Agents"
        case .chats: return "Chats"
        case .pulls: return "Pull requests"
        case .settings: return "Settings"
        }
    }

    /// The tab's icon; the filled form when it is the chosen tab where one exists.
    func symbol(selected: Bool) -> String {
        switch self {
        case .nook: return "sparkles"
        case .agents: return selected ? "square.stack.3d.up.fill" : "square.stack.3d.up"
        case .chats: return selected ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right"
        case .pulls: return "arrow.triangle.pull"
        case .settings: return selected ? "gearshape.fill" : "gearshape"
        }
    }
}

/// Which tab shows: shared, so the header every tab starts with can switch.
@MainActor
final class TabRouter: ObservableObject {
    @Published var tab = CompanionTab.nook
    /// On the phone: pull requests or Settings, open as a sheet over the tab you were in.
    @Published var sheet: CompanionTab?
    /// A chat in your apps to open on the Chats tab (from "For you" on the Nook tab).
    @Published var openChat: String?

    /// The tabs this phone may use: one the Mac does not allow it (`CompanionScope`), or cannot serve, is left out.
    func available(_ client: CompanionClient) -> [CompanionTab] {
        CompanionTab.allCases.filter { tab in
            switch tab {
            case .nook: return client.allows(.nookChat)
            case .agents, .settings: return true
            case .chats: return client.allows(.chats)
            case .pulls: return client.allows(.read) && client.can(CompanionFeature.pullRequests)
            }
        }
    }

    /// The badge on a tab: what waits for you there.
    func count(_ tab: CompanionTab, _ client: CompanionClient) -> Int {
        switch tab {
        case .nook: return client.conversations.filter(\.waiting).count
        case .agents: return client.sessions.filter(SessionListView.needsYou).count
        // Chats with something unread, not every message: one busy group is one.
        case .chats: return client.inbox.count(where: { $0.unread > 0 })
        case .pulls, .settings: return 0
        }
    }
}

/// The row on top of every tab: Nook's orb (its menu holds the Mac, the connection and Live Activities), the tab's name
/// large with the Mac's name and how it is connected (such as "Reconnecting…") under it, and the tab's own round button
/// on the right. The tabs themselves are along the bottom.
struct PanelHeader<Trailing: View>: View {
    @EnvironmentObject private var router: TabRouter
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.isPresented) private var isPresented
    @Environment(\.dismiss) private var dismiss
    /// The page's own name where it is not the tab's (Settings in its sheet).
    var title: LocalizedStringKey? = nil
    /// The gear to Settings, on the phone where Settings is not a tab.
    var showsSettings = true
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            MacMenu()
            VStack(alignment: .leading, spacing: 0) {
                Text(title ?? router.tab.title)
                    .font(Theme.TextStyle.display)
                    .foregroundStyle(Theme.paper)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                ConnectionTitle()
            }
            Spacer(minLength: 0)
            trailing()
            if isPresented {
                NookIconButton(systemName: "xmark", label: String(localized: "Close")) { dismiss() }
            } else if showsSettings, sizeClass != .regular {
                NookIconButton(systemName: "gearshape", label: String(localized: "Settings")) {
                    Haptics.tap()
                    router.sheet = .settings
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: LocalizedStringKey? = nil, showsSettings: Bool = true) {
        self.init(title: title, showsSettings: showsSettings) { EmptyView() }
    }
}

/// Under the tab's name: the computer and how the phone has it. "MacBook · live" while connected,
/// "Catching up…" while it synchronizes, and "Looking for MacBook…" once it has been away for a moment (not at a short
/// drop). With one computer paired a tap on it while away explains why; with several it is the quick switcher: a tap
/// lists every paired computer with its state and what waits there (`ComputerChoices`).
struct ConnectionTitle: View {
    @EnvironmentObject private var client: CompanionClient
    @State private var diagnosing = false

    private var mac: String { client.macName.isEmpty ? client.fallbackComputerName : client.macName }
    private var switchable: Bool { client.macs.count > 1 }

    var body: some View {
        Group {
            if switchable {
                Menu {
                    ComputerChoices()
                    Section {
                        Button { diagnosing = true } label: { Label("Check the connection", systemImage: "stethoscope") }
                        Button { client.addingMac = true } label: { Label("Pair another computer", systemImage: "plus") }
                    }
                } label: {
                    status
                }
                .buttonStyle(PressFade())
                .accessibilityHint(Text("Switch to another computer"))
            } else if case .offline = client.phase {
                Button { diagnosing = true } label: { status }
                    .buttonStyle(PressFade())
            } else {
                status
            }
        }
        .animation(Theme.reveal, value: client.phase)
        .animation(Theme.reveal, value: client.synchronizing)
        .sheet(isPresented: $diagnosing) { DiagnosisSheet() }
    }

    @ViewBuilder
    private var status: some View {
        switch client.phase {
        case .connected where client.synchronizing:
            label(String(localized: "\(mac) · catching up…"), dot: Theme.blue)
        case .connected:
            label(String(localized: "\(mac) · live"), dot: Theme.mint)
        case .offline:
            label(String(localized: "Looking for \(mac)…"), dot: Theme.amber)
                .appearsAfterDelay()
        default:
            EmptyView()
        }
    }

    private func label(_ text: String, dot: Color) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
            if switchable {
                Image(icon: "chevron.down").imageScale(.small)
            }
        }
        .font(Theme.TextStyle.detail)
        .foregroundStyle(Theme.textTertiary)
        .transition(.opacity)
    }
}

/// Every paired computer, as a menu's checked list: its icon (a Mac, or a PC with Nook on Windows or Linux), its name, and
/// under it whether it is live or can be reached and how much waits there (from the check of the others every 30
/// seconds). Choosing one moves the live connection there. Used by the quick switcher under the tab title and by the
/// orb's menu, so both read the same.
struct ComputerChoices: View {
    @EnvironmentObject private var client: CompanionClient

    var body: some View {
        Picker(selection: Binding(get: { client.activeMacID ?? "" }, set: { client.switchMac(to: $0) })) {
            ForEach(client.macs) { mac in
                Label {
                    Text(mac.name)
                    let status = client.computerStatus(mac)
                    if !status.isEmpty { Text(status) }
                } icon: {
                    Image(icon: mac.kind.symbol)
                }
                .tag(mac.id)
            }
        } label: {
            Text("Computers")
        }
        .pickerStyle(.inline)
    }
}

extension CompanionClient {
    /// "your Mac", or "your computer" when the active one is Nook on Windows or Linux: where its name is not known yet.
    var fallbackComputerName: String {
        platform.isMac ? String(localized: "your Mac") : String(localized: "your computer")
    }

    /// The same at the start of a title ("Your Mac", "Your computer").
    var fallbackComputerTitle: String {
        platform.isMac ? String(localized: "Your Mac") : String(localized: "Your computer")
    }

    /// How many sessions wait on you on a paired computer: the live list of the active one, the last check of another.
    func waiting(on mac: PairedMac) -> Int {
        (mac.id == activeMacID ? sessions : otherSessions[mac.id] ?? []).needingYou
    }

    /// A computer's line in the switcher: "Live · 2 waiting on you", "Offline", "Online"; empty for one not checked yet
    /// with nothing waiting.
    func computerStatus(_ mac: PairedMac) -> String {
        let state: String?
        if mac.id == activeMacID {
            state = phase == .connected ? String(localized: "Live") : String(localized: "Not connected")
        } else {
            state = otherReachable[mac.id].map { $0 ? String(localized: "Online") : String(localized: "Offline") }
        }
        let count = waiting(on: mac)
        let waits = count > 0 ? String(localized: "\(count) waiting on you") : nil
        return [state, waits].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Nook's orb, and under it what the phone knows about the computer: which one (and switching to another), how it is
/// reached, Live Activities, checking the connection, and unpairing. A small amber dot on the orb while the computer
/// cannot be reached.
struct MacMenu: View {
    @EnvironmentObject private var client: CompanionClient
    @ObservedObject private var live = LiveActivities.shared
    @State private var diagnosing = false

    private var offline: Bool {
        if case .offline = client.phase { return true }
        return false
    }

    var body: some View {
        Menu {
            // Every paired computer: the live connection goes to the one that is checked.
            if client.macs.count > 1 {
                ComputerChoices()
            }
            Section(client.macName.isEmpty ? client.fallbackComputerTitle : client.macName) {
                // How the phone reaches the computer right now: the local network, Tailscale, or the relay.
                if client.phase == .connected, let route = client.activeRoute {
                    Label(RouteText.connected(route), systemImage: RouteText.symbol(route))
                }
                Button { diagnosing = true } label: { Label("Check the connection", systemImage: "stethoscope") }
            }
            Section {
                // Sessions working on the computer on the Lock Screen and in the Dynamic Island.
                if client.can(CompanionFeature.liveActivity) {
                    Toggle(isOn: $live.enabled) { Label("Live Activities", systemImage: "platter.filled.top.iphone") }
                        .disabled(!live.allowedBySystem)
                }
                if client.macPushReady == false {
                    Label("Push notifications are not ready on your Mac yet (Settings › iPhone companion).",
                          systemImage: "bell.slash")
                }
                if client.hasUnrecognizedMacFeatures {
                    Label("Update Nook Companion to use everything your Mac offers.", systemImage: "arrow.down.circle")
                }
                // Opens the update panel on the Mac; installing stays a click there.
                if client.can(CompanionFeature.requestUpdate) {
                    Button { Task { await client.requestMacUpdate() } } label: {
                        Label("Show the update on your Mac", systemImage: "arrow.down.circle")
                    }
                }
            }
            Section {
                Button { client.addingMac = true } label: { Label("Pair another computer", systemImage: "plus") }
                Button("Unpair from this computer", role: .destructive) { client.unpair() }
            }
        } label: {
            NookMark(size: 30)
                .overlay(alignment: .bottomTrailing) {
                    if offline {
                        Circle().fill(Theme.amber).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .accessibilityLabel("Nook and your computer")
        .sheet(isPresented: $diagnosing) { DiagnosisSheet() }
    }
}

/// The title of a pushed screen in the navigation bar, as the Mac's task header: the title, and under it in quieter
/// text whose or where it is.
struct SheetTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(Theme.TextStyle.strong).foregroundStyle(Theme.paper).lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: 240)
    }
}

// MARK: Buttons

/// A press that dims what was tapped a little: the phone's stand-in for the Mac's hover. Under an iPad's pointer the
/// system's highlight shows what a click hits.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Theme.hover, value: configuration.isPressed)
            .hoverEffect(.highlight)
    }
}

/// A list row: lit with `rowHover` while your finger is on it, or an iPad's pointer is over it, as the Mac lights the
/// row under the pointer.
struct RowPress: ButtonStyle {
    var radius = Theme.Radius.card

    func makeBody(configuration: Configuration) -> some View {
        RowPressBody(label: configuration.label, pressed: configuration.isPressed, radius: radius)
    }
}

private struct RowPressBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let radius: CGFloat
    @State private var hovered = false

    var body: some View {
        label
            .roundedBackground(pressed || hovered ? Theme.rowHover : Color.clear, radius: radius)
            .contentShape(.hoverEffect, Theme.shape(radius))
            .onHover { hovered = $0 }
            .animation(Theme.hover, value: pressed || hovered)
    }
}

// MARK: Notices and fields

/// The one search field, the Mac's `NookSearchField` (`panel` style): a magnifying glass, the text and a clear button on
/// `field`, without an edge.
struct NookSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @FocusState private var isFocused: Bool
    /// ⌘F or ⌘K on a hardware keyboard: the field on screen takes the keys.
    @Environment(\.searchFocusRequest) private var searchRequest

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(icon: "magnifyingglass")
                .font(Theme.textFont(11, .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $text)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.paper)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    Haptics.tap()
                    text = ""
                } label: {
                    Image(icon: "xmark.circle.fill")
                        .font(Theme.textFont(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, Theme.Spacing.md)
        .padding(.trailing, Theme.Spacing.xxs)
        .frame(minHeight: 38)
        .roundedBackground(Theme.field, radius: Theme.Radius.control)
        // Also when the field only appeared because of the request: it gets the keys once it is on screen.
        .onChange(of: searchRequest, initial: true) { _, request in
            if request.isFresh { isFocused = true }
        }
    }
}

// MARK: The composer

/// The box you write to an agent, to Nook or in a chat, the Mac's `SessionComposer`: one quiet surface with a faint
/// outline and a light along its top edge, the text 16 pt in, the round send button in Nook's color 8 pt from the
/// corner (a stop button while work runs). With `controls` the turn's choices sit in a row under the text, as when
/// starting a session; without, the box is one line and the button sits beside the text.
struct SessionComposer<Controls: View>: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    /// Room for the text before you type: a few lines when starting a session, one when answering.
    var minHeight: CGFloat = 22
    var lines: ClosedRange<Int> = 1...6
    /// Anything besides an empty text that keeps the message from going out.
    var canSend = true
    var sending = false
    /// Something goes besides words (a picture, a file): Send works with the field empty.
    var allowsEmpty = false
    /// Work runs: the button stops it instead of sending (when `onStop` is given).
    var busy = false
    var onStop: (() -> Void)? = nil
    var focus: FocusState<Bool>.Binding? = nil
    /// Offers the microphone next to Send (`DictationButton`).
    var dictates = true
    let onSend: () -> Void
    @ViewBuilder var controls: () -> Controls

    @FocusState private var ownFocus: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var enabled: Bool { canSend && !sending && (!isEmpty || allowsEmpty) }
    private var hasControls: Bool { Controls.self != EmptyView.self }

    var body: some View {
        let focused = focus ?? $ownFocus
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if hasControls {
                field(focused).frame(minHeight: minHeight, alignment: .topLeading)
                HStack(spacing: Theme.Spacing.xs) {
                    controls()
                    Spacer(minLength: Theme.Spacing.md)
                    sendButton
                }
                .padding(.leading, -Theme.Spacing.md)
            } else {
                HStack(alignment: .bottom, spacing: Theme.Spacing.md) {
                    field(focused).frame(minHeight: 32, alignment: .center)
                    sendButton
                }
            }
        }
        .padding(.leading, Theme.Spacing.xl)
        .padding(.trailing, Theme.Spacing.md)
        .padding(.top, hasControls ? Theme.Spacing.xl : Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
        .background(shape.fill(Theme.surface))
        .overlay(shape.strokeBorder(focused.wrappedValue ? Theme.iris.opacity(0.28) : Theme.fieldStroke, lineWidth: 1))
        .overlay(shape.strokeBorder(LinearGradient(colors: [Theme.paper.opacity(0.06), Theme.paper.opacity(0)],
                                                   startPoint: .top, endPoint: .center), lineWidth: 1).allowsHitTesting(false))
        .animation(Theme.reveal, value: focused.wrappedValue)
        .contentShape(shape)
        .onTapGesture { focused.wrappedValue = true }
    }

    private var shape: RoundedRectangle { Theme.shape(Theme.Radius.composer) }

    private func field(_ focused: FocusState<Bool>.Binding) -> some View {
        TextField(prompt, text: $text, axis: .vertical)
            .font(Theme.TextStyle.body)
            .foregroundStyle(Theme.paper)
            .tint(Theme.paper)
            .lineLimit(lines)
            .focused(focused)
    }

    @ViewBuilder
    private var sendButton: some View {
        // Dictation next to Send, in every composer (`DictationButton`); what is heard lands in the field to read first.
        if dictates { DictationButton(text: $text) }
        if busy, isEmpty, let onStop {
            round("stop.fill", label: "Stop", active: true, action: onStop)
        } else {
            round("arrow.up", label: "Send", active: enabled) { onSend() }
                .disabled(!enabled)
                // ⌘↩ on a hardware keyboard sends, as on the Mac; only from the composer you type in, so a second one
                // on screen (the iPad's list beside a session) never takes it.
                .keyboardShortcut((focus ?? $ownFocus).wrappedValue ? KeyboardShortcut(.return, modifiers: .command) : nil)
        }
    }

    private func round(_ symbol: String, label: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            // The Mac's round button (`SessionComposer.roundButton`): Nook's color when it can go, `smoke` when not.
            ZStack {
                Circle().fill(active ? Theme.iris : Theme.smoke)
                if sending {
                    ProgressView().controlSize(.small).tint(Theme.onIris)
                } else {
                    Image(icon: symbol).font(Theme.font(13, .bold))
                        .foregroundStyle(active ? Theme.onIris : Theme.textTertiary)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

extension SessionComposer where Controls == EmptyView {
    init(text: Binding<String>, prompt: LocalizedStringKey, minHeight: CGFloat = 22, lines: ClosedRange<Int> = 1...6,
         canSend: Bool = true, sending: Bool = false, busy: Bool = false,
         onStop: (() -> Void)? = nil, focus: FocusState<Bool>.Binding? = nil, onSend: @escaping () -> Void) {
        self.init(text: text, prompt: prompt, minHeight: minHeight, lines: lines, canSend: canSend, sending: sending, busy: busy, onStop: onStop, focus: focus,
                  onSend: onSend) { EmptyView() }
    }
}

/// A quiet choice inside or under the composer, the Mac's `ComposerPill`: an agent's logo, a symbol or a dot, a short
/// text and a chevron when it opens a menu.
struct ComposerPill: View {
    var symbol: String? = nil
    var dot: Color? = nil
    var agent: String? = nil
    let text: String
    var tint: Color? = nil
    var showsChevron = true

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let agent {
                AgentLogo(agent: agent, size: 16)
            } else if let dot {
                Circle().fill(dot).frame(width: 7, height: 7)
            } else if let symbol {
                Image(icon: symbol).font(Theme.font(12, .medium))
            }
            if !text.isEmpty { Text(text).lineLimit(1) }
            if showsChevron {
                Image(icon: "chevron.down").font(Theme.font(9, .bold)).opacity(0.6)
            }
        }
        .font(Theme.TextStyle.label)
        .foregroundStyle(tint ?? Theme.textSecondary)
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: 32)
        .contentShape(Rectangle())
    }
}

/// The room between two groups of choices in the composer: a gap, not a line.
struct ComposerDivider: View {
    var body: some View { Color.clear.frame(width: Theme.Spacing.xs, height: 16) }
}

/// A tray tucked against the composer box, the Mac's `ComposerTray`: under the box of a new session (where it works),
/// above the box of a chat (the message you answer). Put it next to the box in a `VStack(spacing: 0)` and give the box
/// `.zIndex(1)`.
struct ComposerTray<Content: View>: View {
    var edge: VerticalEdge = .bottom
    @ViewBuilder let content: Content

    private static var tuck: CGFloat { 16 }

    var body: some View {
        let inner: Edge.Set = edge == .bottom ? .top : .bottom
        let outer: Edge.Set = edge == .bottom ? .bottom : .top
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(inner, Self.tuck + Theme.Spacing.xs)
            .padding(outer, Theme.Spacing.sm)
            .background(shape.fill(Theme.field))
            .overlay(shape.strokeBorder(Theme.fieldStroke, lineWidth: 1))
            .padding(inner, -Self.tuck)
            .padding(.horizontal, Theme.Spacing.xl + Theme.Spacing.sm)
    }

    private var shape: UnevenRoundedRectangle {
        let radius = Theme.Radius.bubble
        return edge == .bottom
            ? UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .continuous)
    }
}

/// Where a conversation's composer sits: at the bottom over the canvas, fading the messages out behind it.
struct ComposerDock<Content: View>: View {
    @EnvironmentObject private var client: CompanionClient
    /// The color the messages fade into: the canvas, or a chat's own wallpaper.
    var fill: Color = Theme.canvas
    /// What the strip says while the Mac cannot be reached: whether you write here or only read.
    var offline: OfflineStrip.Kind = .sends
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            // Without the Mac the app still reads and writes, and says so where you write: nothing new comes in, and
            // what you send waits on this iPhone (the outbox) until the Mac answers. A Mac too old for that takes
            // nothing until it is connected again.
            if client.isOffline {
                OfflineStrip(kind: offline).appearsAfterDelay()
            }
            content.disabled(client.isOffline && offline == .sends && !client.writingWaits)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.md)
        .background(LinearGradient(colors: [fill.opacity(0), fill], startPoint: .top,
                                   endPoint: UnitPoint(x: 0.5, y: 0.3)))
    }
}

// MARK: Starters

/// Starters for a chat with Nook, two per row, the Mac's `SuggestionGrid`: the icon beside the question on `field`.
struct SuggestionGrid: View {
    let suggestions: [String]
    let ask: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.md), GridItem(.flexible(), spacing: Theme.Spacing.md)],
                  alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { ask(suggestion) } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        HomeLogo(content: .symbol("sparkles"), size: 26)
                        Text(suggestion)
                            .font(Theme.TextStyle.body)
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.md)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .roundedBackground(Theme.field, radius: Theme.Radius.panel)
                    .roundedHitShape(Theme.Radius.panel)
                }
                .buttonStyle(RowPress(radius: Theme.Radius.panel))
            }
        }
    }
}

// MARK: Drafts

extension View {
    /// Keeps what is typed in `text` for `place` (`PhoneDrafts`), as the Mac keeps a composer's draft: it is back when
    /// you return, also after the app was closed, and gone once it is sent or cleared. Nil keeps nothing.
    func keepsDraft(_ text: Binding<String>, for place: PhoneDrafts.Place?) -> some View {
        modifier(KeepsDraft(text: text, place: place))
    }
}

private struct KeepsDraft: ViewModifier {
    @Binding var text: String
    let place: PhoneDrafts.Place?

    func body(content: Content) -> some View {
        content
            .onAppear { restore() }
            .onChange(of: place) { _, _ in restore() }
            .onChange(of: text) { _, text in
                guard let place else { return }
                PhoneDrafts().set(text, for: place)
            }
    }

    /// Fills an empty field with the draft; what the screen opened with (a prompt link, a shared text) stays.
    private func restore() {
        guard let place, text.isEmpty else { return }
        let draft = PhoneDrafts().text(place)
        if !draft.isEmpty { text = draft }
    }
}
