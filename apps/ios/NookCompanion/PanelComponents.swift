import SwiftUI

// The Mac panel's building blocks (apps/macos/NotchUI/Components, docs/UI-COMPONENTS.md), made for the phone: the same
// names, shapes and colors, with touch instead of hover (a press lights what the pointer lights on the Mac) and room for
// a finger. Change one here and every screen follows, as on the Mac.

// MARK: Logos

/// The mark of a coding agent, the Mac's `AgentLogo`: the real brand mark where there is one (`BrandMark`, shared with the
/// Mac app), Antigravity's arch, and a letter for the rest.
struct AgentLogo: View {
    let agent: String
    var size: CGFloat = 16

    var body: some View {
        let name = agent.lowercased()
        Group {
            if name.contains("antigravity") {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color(hex: 0x17171B))
                    .overlay(
                        ArchGlyph()
                            .stroke(LinearGradient(colors: [Color(hex: 0x4F8BF7), Color(hex: 0xEA4335), Color(hex: 0xFBBC04)],
                                                   startPoint: .bottomLeading, endPoint: .topTrailing),
                                    style: StrokeStyle(lineWidth: max(1, size * 0.09), lineCap: .round, lineJoin: .round))
                            .padding(size * 0.22)
                    )
            } else if let brand = BrandLogo.forName(name) {
                BrandMark(logo: brand, size: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Theme.textSecondary.opacity(0.2))
                    .overlay(Text(String(agent.prefix(1)).uppercased()).font(Theme.rounded(size * 0.52, .bold)).foregroundStyle(Theme.textStrong))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent)
    }
}

/// An "A" without its point cut off: two legs and a bar (Antigravity).
private struct ArchGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.66))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.26, y: rect.minY + rect.height * 0.66))
        return path
    }
}

/// The real logo of a coding agent (`AgentLogo`) on a neutral tile, as the Mac's `HomeLogo`. Grey in a list, as on the
/// Mac (an agent's color lives in its logo, and only where you look at that one agent); `colored` shows its own colors.
struct AgentIcon: View {
    let agent: String
    var size: CGFloat = 36
    var colored = false

    var body: some View {
        AgentMark(agent: agent, size: size * 0.56, quiet: !colored)
            .frame(width: size, height: size)
            .background(Theme.text.opacity(0.05), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }

    /// An agent's own color for charts, by display name or id ("Claude Code" or "claude").
    static func style(_ agent: String) -> (symbol: String, color: Color) {
        let name = agent.lowercased()
        if name.contains("claude") { return ("asterisk", Color(hex: 0xE38B6D)) }
        if name.contains("codex") { return ("chevron.left.forwardslash.chevron.right", Theme.text) }
        if name.contains("gemini") { return ("sparkle", Color(hex: 0x8AB4F8)) }
        if name.contains("opencode") { return ("terminal.fill", Theme.mint) }
        if name.contains("cursor") { return ("cursorarrow.rays", Theme.text) }
        if name.contains("grok") { return ("bolt.fill", Theme.text) }
        if name.contains("antigravity") { return ("atom", Theme.violet) }
        return ("cpu", Theme.textStrong)
    }
}

/// An agent's logo as a row shows it, the Mac's `AgentMark`: grey and a little faded when `quiet` (a list at rest), its
/// own colors otherwise.
struct AgentMark: View {
    let agent: String
    var size: CGFloat = 16
    var quiet = false

    var body: some View {
        AgentLogo(agent: agent, size: size)
            .saturation(quiet ? 0 : 1)
            .opacity(quiet ? 0.6 : 1)
    }
}

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
            case .symbol(let name): Image(systemName: name).font(Theme.font(size * 0.42, .medium)).foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(tileFill, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .accessibilityHidden(true)
    }

    private var tileFill: Color {
        switch content {
        case .agent: return Theme.text.opacity(0.05)
        case .symbol: return tint.opacity(0.12)
        }
    }
}

// MARK: Headers

/// The title row on top of a tab, the Mac's `PanelListHeader` with Nook beside it as in the panel's header: Nook's
/// orb, the name, what waits (`CountBadge`), and the tab's own round buttons on the right. Every tab starts with this
/// same row, so they line up when you switch.
struct PanelHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var count: Int = 0
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            NookMark(size: 30)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Spacing.md) {
                    Text(title).font(Theme.TextStyle.pageTitle).foregroundStyle(Theme.text).lineLimit(1)
                    CountBadge(count: count)
                }
                if let subtitle {
                    Text(subtitle).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.md) { trailing() }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, count: Int = 0, subtitle: String? = nil) {
        self.init(title: title, count: count, subtitle: subtitle) { EmptyView() }
    }
}

/// The title of a pushed screen in the navigation bar, as the Mac's task header: the title, and under it in quieter
/// text whose or where it is.
struct SheetTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(Theme.TextStyle.caption).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: 240)
    }
}

// MARK: Buttons

/// The round symbol button of the panel's header, the Mac's `NookIconButton`: a quiet grey circle.
struct NookIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var size: CGFloat = 36
    let action: () -> Void

    var body: some View {
        Button(action: action) { NookIconLabel(symbol: symbol, size: size) }
            .buttonStyle(PressFade())
            .accessibilityLabel(label)
    }
}

/// The look of `NookIconButton`, for a `Menu`'s label.
struct NookIconLabel: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.font(size * 0.4, .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(Theme.raised, in: Circle())
            .contentShape(Circle())
    }
}

/// One action of a notice (Allow, Deny, Answer).
struct NoticeAction {
    let label: LocalizedStringKey
    var symbol: String? = nil
    let perform: () -> Void
}

/// The main action and its "not now" in one pill, the Mac's `NookSplitButton`: the main one in paper on the left, the
/// other as quiet text beside it, both on one grey capsule.
struct NookSplitButton: View {
    let primary: NoticeAction
    let secondary: NoticeAction

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primary.perform) {
                HStack(spacing: Theme.Spacing.sm) {
                    if let symbol = primary.symbol { Image(systemName: symbol).font(Theme.font(13, .bold)) }
                    Text(primary.label).font(Theme.TextStyle.strong)
                }
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, Theme.Spacing.xl + Theme.Spacing.xxs)
                .frame(maxHeight: .infinity)
                .background(Theme.text, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PressFade())
            Button(action: secondary.perform) {
                HStack(spacing: Theme.Spacing.sm) {
                    if let symbol = secondary.symbol { Image(systemName: symbol).font(Theme.font(13, .semibold)) }
                    Text(secondary.label).font(Theme.TextStyle.strong)
                }
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.leading, Theme.Spacing.lg + Theme.Spacing.xxs)
                .padding(.trailing, Theme.Spacing.xl + Theme.Spacing.xxs)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
        }
        .padding(3)
        .frame(height: 42)
        .background(Theme.raised, in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// A press that dims what was tapped a little: the phone's stand-in for the Mac's hover.
struct PressFade: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// A list row: lit with `rowPressed` while your finger is on it, as the Mac lights the row under the pointer.
struct RowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.rowPressed : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .animation(Theme.press, value: configuration.isPressed)
    }
}

// MARK: Notices and fields

/// A request that waits for you, the Mac's `PanelNoticeBar`: its mark, a title and a line, and its own actions under it,
/// on `surface` with a faint edge in its tone.
struct NoticeCard<Actions: View>: View {
    let title: String
    var detail: String? = nil
    var symbol: String
    var tone: Color = Theme.amber
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                Image(systemName: symbol).font(Theme.font(14, .semibold)).foregroundStyle(tone)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text).lineLimit(3)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.TextStyle.detail).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    }
                }
            }
            actions()
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous).strokeBorder(tone.opacity(0.35), lineWidth: 1))
    }
}

/// The one search field, the Mac's `NookSearchField`: a magnifying glass, the text and a clear button on `field`.
struct NookSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "magnifyingglass").font(Theme.font(14, .medium)).foregroundStyle(Theme.textTertiary)
            TextField(prompt, text: $text)
                .font(Theme.TextStyle.body)
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textTertiary)
                }
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 40)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
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
        .background(shape.fill(Theme.surface))
        .overlay(shape.strokeBorder(focused.wrappedValue ? Theme.iris.opacity(0.28) : Theme.fieldStroke, lineWidth: 1))
        .overlay(shape.strokeBorder(LinearGradient(colors: [Theme.text.opacity(0.06), Theme.text.opacity(0)],
                                                   startPoint: .top, endPoint: .center), lineWidth: 1).allowsHitTesting(false))
        .animation(Theme.reveal, value: focused.wrappedValue)
        .contentShape(shape)
        .onTapGesture { focused.wrappedValue = true }
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous) }

    private func field(_ focused: FocusState<Bool>.Binding) -> some View {
        TextField(prompt, text: $text, axis: .vertical)
            .font(Theme.TextStyle.body)
            .foregroundStyle(Theme.text)
            .tint(Theme.text)
            .lineLimit(lines)
            .focused(focused)
    }

    @ViewBuilder
    private var sendButton: some View {
        if busy, isEmpty, let onStop {
            round("stop.fill", label: "Stop", active: true, action: onStop)
        } else {
            round("arrow.up", label: "Send", active: enabled) { onSend() }
                .disabled(!enabled)
        }
    }

    private func round(_ symbol: String, label: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if sending {
                    ProgressView().controlSize(.small).tint(Theme.onIris)
                } else {
                    Image(systemName: symbol).font(Theme.font(14, .bold))
                }
            }
            .foregroundStyle(active ? Theme.onIris : Theme.textTertiary)
            .frame(width: 34, height: 34)
            .background(active ? Theme.iris : Theme.raised, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(PressFade())
        .accessibilityLabel(label)
        .animation(Theme.press, value: active)
    }
}

extension SessionComposer where Controls == EmptyView {
    init(text: Binding<String>, prompt: LocalizedStringKey, canSend: Bool = true, sending: Bool = false, busy: Bool = false,
         onStop: (() -> Void)? = nil, focus: FocusState<Bool>.Binding? = nil, onSend: @escaping () -> Void) {
        self.init(text: text, prompt: prompt, canSend: canSend, sending: sending, busy: busy, onStop: onStop, focus: focus,
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
                Image(systemName: symbol).font(Theme.font(12, .medium))
            }
            Text(text).lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down").font(Theme.font(9, .bold)).opacity(0.6)
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

/// Starters for a chat with Nook, two per row, the Mac's `SuggestionGrid`.
struct SuggestionGrid: View {
    let suggestions: [String]
    let ask: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.Spacing.md), GridItem(.flexible(), spacing: Theme.Spacing.md)],
                  alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button { ask(suggestion) } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HomeLogo(content: .symbol("sparkles"), size: 26)
                        Text(suggestion)
                            .font(Theme.TextStyle.detail)
                            .foregroundStyle(Theme.textStrong)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
                }
                .buttonStyle(PressFade())
            }
        }
    }
}
