import SwiftUI

// The phone's panel: its header, tabs, search field, composer and starters, drawn as the Mac's (docs/UI-COMPONENTS.md)
// with touch instead of hover (a press lights what the pointer lights on the Mac) and room for a finger. The buttons,
// badges, list parts and agent logos are not here: both apps compile those from apps/macos/NotchUI/Shared.

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
        .background(tileFill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
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

/// The panel's tabs, in the Mac's order (`PanelTab.visible`): Nook, Agents, Chats.
enum CompanionTab: Hashable, CaseIterable {
    case nook, agents, chats

    var title: LocalizedStringKey {
        switch self {
        case .nook: return "Nook"
        case .agents: return "Agents"
        case .chats: return "Chats"
        }
    }

    /// Its icon in the tab bar.
    var symbol: String {
        switch self {
        case .nook: return "sparkles"
        case .agents: return "terminal"
        case .chats: return "bubble.left"
        }
    }
}

/// Which tab shows: shared, so the header every tab starts with can switch.
@MainActor
final class TabRouter: ObservableObject {
    @Published var tab = CompanionTab.nook

    /// The tabs this phone may use: one the Mac does not allow it (`CompanionScope`) is left out.
    func available(_ client: CompanionClient) -> [CompanionTab] {
        CompanionTab.allCases.filter { tab in
            switch tab {
            case .nook: return client.allows(.nookChat)
            case .agents: return true
            case .chats: return client.allows(.chats)
            }
        }
    }
}

/// The row on top of every tab, after t3code's iPhone app: Nook's orb on the left (its menu holds the Mac, the connection
/// and Live Activities), the tab's title in the middle with how current what it shows is under it (`FreshnessLine`), and
/// the tab's own round buttons on the right. The tabs themselves are at the bottom (`PhoneTabBar`).
struct PanelHeader<Trailing: View>: View {
    @EnvironmentObject private var router: TabRouter
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            MacMenu()
            Spacer(minLength: 0)
            HStack(spacing: Theme.Spacing.sm) { trailing() }
        }
        .frame(minHeight: 44)
        .overlay {
            VStack(spacing: 0) {
                Text(router.tab.title).font(Theme.TextStyle.screenTitle).foregroundStyle(Theme.paper).lineLimit(1)
                FreshnessLine()
            }
            .padding(.horizontal, 96)
            .allowsHitTesting(false)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.md)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init() { self.init { EmptyView() } }
}

/// A round button in a header, t3code's: an icon on floating glass, 40 pt, so it reads as one with the orb beside it.
struct HeaderButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(icon: symbol)
                .font(Theme.font(16, .semibold))
                .foregroundStyle(Theme.paper)
                .frame(width: 40, height: 40)
                .floatingGlass(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
    }
}

/// Under a tab's title: which Mac, and how current what shows is (`CompanionFreshness`), apart from whether it is
/// connected: "Live" with a live connection, "Updated 3 min ago" when answers stopped coming, "Not connected" when the Mac
/// cannot be reached. A dot carries the state: mint when current, amber when not.
struct FreshnessLine: View {
    @EnvironmentObject private var client: CompanionClient

    var body: some View {
        let freshness = client.freshness
        HStack(spacing: Theme.Spacing.xs) {
            Circle().fill(Self.current(freshness) ? Theme.mint : Theme.amber).frame(width: 6, height: 6)
            Text(verbatim: text(freshness)).lineLimit(1).truncationMode(.middle)
        }
        .font(Theme.TextStyle.caption)
        .foregroundStyle(Theme.textTertiary)
        .accessibilityElement(children: .combine)
    }

    static func current(_ freshness: CompanionFreshness) -> Bool {
        switch freshness {
        case .live, .current: return true
        case .behind, .offline: return false
        }
    }

    private func text(_ freshness: CompanionFreshness) -> String {
        let state: String
        switch freshness {
        case .live: state = String(localized: "Live")
        case .current: state = String(localized: "Connected")
        case .behind(let minutes): state = String(localized: "Updated \(minutes) min ago")
        case .offline(let since):
            state = since.map { String(localized: "Not connected · from \($0.formatted(date: .omitted, time: .shortened))") }
                ?? String(localized: "Not connected")
        }
        return client.macName.isEmpty ? state : client.macName + " · " + state
    }
}

/// The tabs, at the bottom as in t3code's iPhone app: one glass bar over the content, an icon and a word per tab, the
/// chosen one lit in blue on a raised pill that slides to the next; what waits for you as a count on its icon (amber for
/// what you have to act on, blue for unread chats). Hidden while a tab shows a pushed screen (a session, a chat).
struct PhoneTabBar: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var router: TabRouter
    @Namespace private var selection

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(router.available(client), id: \.self) { tab in
                item(tab)
            }
        }
        .padding(Theme.Spacing.xs)
        .frame(height: 62)
        .floatingGlass(RoundedRectangle(cornerRadius: PhoneRadius.glass, style: .continuous))
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private func item(_ tab: CompanionTab) -> some View {
        let selected = router.tab == tab
        return Button {
            guard !selected else { return }
            Haptics.tap()
            withAnimation(Theme.reveal) { router.tab = tab }
        } label: {
            VStack(spacing: Theme.Spacing.xxs) {
                Image(icon: tab.symbol)
                    .font(Theme.font(19, selected ? .semibold : .regular))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) { badge(tab).offset(x: 12, y: -6) }
                Text(tab.title).font(Theme.TextStyle.tabBar).lineLimit(1)
            }
            .foregroundStyle(selected ? Theme.blue : Theme.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: PhoneRadius.glass - Theme.Spacing.xs, style: .continuous)
                        .fill(Theme.paper.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(count(tab) > 0 ? Text("\(count(tab))") : Text(""))
    }

    @ViewBuilder
    private func badge(_ tab: CompanionTab) -> some View {
        let count = count(tab)
        if count > 0 {
            Text(count, format: .number)
                .font(Theme.textFont(9, .bold))
                .monospacedDigit()
                .foregroundStyle(tab == .chats ? Theme.paper : Theme.ink)
                .padding(.horizontal, Theme.Spacing.xs)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(tab == .chats ? Theme.blue : Theme.amber))
        }
    }

    private func count(_ tab: CompanionTab) -> Int {
        switch tab {
        case .nook: return client.conversations.filter(\.waiting).count
        case .agents: return client.sessions.needingYou
        // Chats with something unread, not every message: one busy group is one.
        case .chats: return client.inbox.filter { $0.unread > 0 }.count
        }
    }
}

/// Nook's orb, and under it what the phone knows about the Mac: which Mac (and switching to another), how it is
/// reached, Live Activities, checking the connection, and unpairing. A small amber dot on the orb while the Mac
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
            // Every paired Mac: the live connection goes to the one that is checked.
            Section(client.macName.isEmpty ? String(localized: "Your Mac") : client.macName) {
                if client.macs.count > 1 {
                    ForEach(client.macs) { mac in
                        Button { client.switchMac(to: mac.id) } label: {
                            if mac.id == client.activeMacID {
                                Label(mac.name, systemImage: "checkmark")
                            } else {
                                Label(mac.name, systemImage: "laptopcomputer")
                            }
                        }
                    }
                }
                // How the phone reaches the Mac right now: the local network, Tailscale, or the relay.
                if client.phase == .connected, let route = client.activeRoute {
                    Label(RouteText.connected(route), systemImage: RouteText.symbol(route))
                }
                Button { diagnosing = true } label: { Label("Check the connection", systemImage: "stethoscope") }
            }
            Section {
                // Sessions working on the Mac on the Lock Screen and in the Dynamic Island.
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
                Button { client.addingMac = true } label: { Label("Pair another Mac", systemImage: "plus") }
                Button("Unpair from this Mac", role: .destructive) { client.unpair() }
            }
        } label: {
            // On a glass disc, as t3code's header buttons, so the orb and the buttons across from it read as one row.
            NookMark(size: 26)
                .frame(width: 40, height: 40)
                .floatingGlass(Circle())
                .overlay(alignment: .bottomTrailing) {
                    if offline {
                        Circle().fill(Theme.amber).frame(width: 9, height: 9)
                            .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: 2))
                    }
                }
                .contentShape(Circle())
        }
        .accessibilityLabel("Nook and your Mac")
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

/// A press that dims what was tapped a little: the phone's stand-in for the Mac's hover.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Theme.hover, value: configuration.isPressed)
    }
}

/// A list row: lit with `rowHover` while your finger is on it, as the Mac lights the row under the pointer.
struct RowPress: ButtonStyle {
    var radius = PhoneRadius.row

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.rowHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .animation(Theme.hover, value: configuration.isPressed)
    }
}

// MARK: Notices and fields

/// The one search field, the Mac's `NookSearchField` (`panel` style): a magnifying glass, the text and a clear button on
/// `field`, without an edge.
struct NookSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(icon: "magnifyingglass")
                .font(Theme.font(14, .medium))
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
        .padding(.leading, Theme.Spacing.lg)
        .padding(.trailing, Theme.Spacing.xxs)
        .frame(minHeight: 40)
        // t3code's input: the field a step above the screen with a faint edge.
        .background(Theme.field, in: RoundedRectangle(cornerRadius: PhoneRadius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: PhoneRadius.row, style: .continuous).strokeBorder(Theme.fieldStroke, lineWidth: 1))
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
    private var enabled: Bool { canSend && !sending && !isEmpty }
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
        // t3code's composer: a grouped surface at 90 % over a blur, so the conversation shows faintly through it.
        .background(.ultraThinMaterial, in: shape)
        .background(shape.fill(Theme.graphite.opacity(0.9)))
        .overlay(shape.strokeBorder(focused.wrappedValue ? Theme.blue.opacity(0.42) : Theme.paper.opacity(0.06), lineWidth: 1))
        .animation(Theme.reveal, value: focused.wrappedValue)
        .contentShape(shape)
        .onTapGesture { focused.wrappedValue = true }
    }

    /// t3code's 27 pt for one line; a box with choices under its text is a card (`PhoneRadius.card`).
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: hasControls ? PhoneRadius.card : PhoneRadius.composer, style: .continuous)
    }

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
        }
    }

    private func round(_ symbol: String, label: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            // The Mac's round button (`SessionComposer.roundButton`): Nook's color when it can go, `smoke` when not.
            ZStack {
                Circle().fill(active ? Theme.primary : Theme.smoke)
                if sending {
                    ProgressView().controlSize(.small).tint(Theme.onPrimary)
                } else {
                    Image(icon: symbol).font(Theme.font(14, .bold))
                        .foregroundStyle(active ? Theme.onPrimary : Theme.textTertiary)
                }
            }
            .frame(width: 38, height: 38)
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
            Text(text).lineLimit(1)
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
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.md)
            .background(LinearGradient(colors: [Theme.canvas.opacity(0), Theme.canvas], startPoint: .top,
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
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                }
                .buttonStyle(RowPress(radius: Theme.Radius.panel))
            }
        }
    }
}

// MARK: t3code's buttons and chips

/// A full-width or compact button in t3code's three kinds: `prominent` (the main action, white on dark), `secondary`
/// (a step above the surface, with an edge) and `danger` (coral on a dark coral wash). A card that asks something stacks
/// them full width, a row puts them side by side (`compact`).
struct PhoneActionButton: View {
    enum Style { case prominent, secondary, danger }

    let title: String
    var symbol: String? = nil
    var style: Style = .secondary
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let symbol { Image(icon: symbol).font(Theme.font(compact ? 12 : 14, .bold)) }
                Text(title).lineLimit(1)
            }
            .font(Theme.textFont(compact ? 13 : 14, style == .secondary ? .medium : .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? Theme.Spacing.xl : Theme.Spacing.lg)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 34 : 46)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
    }

    private var foreground: Color {
        switch style {
        case .prominent: return Theme.onPrimary
        case .secondary: return Theme.paper
        case .danger: return Theme.coral
        }
    }

    private var fill: Color {
        switch style {
        case .prominent: return Theme.primary
        case .secondary: return Theme.graphite
        case .danger: return Theme.coral.opacity(0.14)
        }
    }

    private var edge: Color {
        switch style {
        case .prominent: return .clear
        case .secondary: return Theme.line2
        case .danger: return Theme.coral.opacity(0.32)
        }
    }
}

/// The project filter above the Agents list, as t3code's: "All" and each folder the sessions work in, one row that
/// scrolls sideways; the chosen chip is white.
struct ProjectChips: View {
    let projects: [String]
    @Binding var chosen: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                chip(String(localized: "All"), selected: chosen == nil) { chosen = nil }
                ForEach(projects, id: \.self) { project in
                    chip(project, selected: chosen == project) { chosen = chosen == project ? nil : project }
                }
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            withAnimation(Theme.reveal) { action() }
        } label: {
            Text(verbatim: title)
                .font(Theme.textFont(12, selected ? .bold : .medium))
                .foregroundStyle(selected ? Theme.onPrimary : Theme.paper)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.lg)
                .frame(height: 30)
                .background(Capsule().fill(selected ? Theme.primary : Theme.surface))
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.line, lineWidth: 1))
        }
        .buttonStyle(PressFade())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: Grouped sections (sheets)

/// Rows that belong together in a sheet, as t3code's grouped list: one surface with 24 pt corners, the rows on it
/// separated by inset hairlines (`SheetDivider`).
struct SheetGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: PhoneRadius.group, style: .continuous))
    }
}

/// The hairline between two rows of a `SheetGroup`, inset to their text.
struct SheetDivider: View {
    var body: some View {
        NookDivider(inset: Theme.Spacing.xl, tint: Theme.separator)
    }
}

/// A choice in a `SheetGroup`: its name, the value chosen (an agent with its mark) and a chevron; a tap opens the menu.
struct SheetMenuRow<Items: View>: View {
    let title: String
    let value: String
    var agent: String? = nil
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            HStack(spacing: Theme.Spacing.md) {
                Text(verbatim: title).font(Theme.TextStyle.rowTitle).foregroundStyle(Theme.paper)
                Spacer(minLength: Theme.Spacing.md)
                if let agent { AgentMark(agent: agent, size: 16) }
                Text(verbatim: value).font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Image(icon: "chevron.up.chevron.down").font(Theme.font(11, .semibold)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(title), \(value)"))
    }
}

/// A switch in a `SheetGroup`, in t3code's blue when on.
struct SheetToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(verbatim: title).font(Theme.TextStyle.rowTitle).foregroundStyle(Theme.paper)
        }
        .tint(Theme.blue)
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(minHeight: 50)
    }
}
