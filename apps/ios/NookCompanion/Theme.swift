import SwiftUI
import UIKit

/// The companion's one design, the same as Nook on the Mac (`NookTheme` in apps/macos): one neutral grey ramp a step
/// apart, so regions read by their fill and need almost no strokes; paper-white text; and color only where it carries
/// meaning (mint = done, amber = waiting on you, coral = error, blue = working or a link, violet = merged). Nook's own
/// accent is the Mac's default soft white. Every view takes its colors, type, radii and spacing from here.
enum Theme {
    // MARK: Colors (the values of `NookTheme`)

    /// The canvas behind every screen: pure black as the notch and Mac Nook.
    static let canvas = Color(hex: 0x000000)
    /// A sunken well: code, quote blocks and search inputs.
    static let well = Color(hex: 0x080808)
    /// What lifts off the canvas: cards, the composer, a sheet's rows.
    static let surface = Color(hex: 0x121212)
    /// A control or chip on a card, elevated interactive pills.
    static let raised = Color(hex: 0x1E1E22)
    /// The faintest divider between regions.
    static let hairline = Color(hex: 0x1E1E1E)
    /// The line between windows and columns.
    static let border = Color(hex: 0x1F1F1F)
    /// The line between the items of a list: a step brighter than `hairline`.
    static let separator = Color(hex: 0x262626)
    /// The quiet fill of a card that groups rows and of the composer's tray.
    static let field = Color(hex: 0x111111)
    /// The stroke of the composer and its tray at rest.
    static let fieldStroke = Color(hex: 0x282828)
    /// Your own message in a conversation: a soft fill, no edge (the Mac's `NookTheme.bubble`).
    static let bubble = Color(hex: 0x1C1C1C)
    /// A row under your finger (the Mac's `rowHover`).
    static let rowPressed = Color(hex: 0x181818)

    static let text = Color(hex: 0xF5F5F5)
    /// Running text a little softer than `text` (the agent's and Nook's answers).
    static let textStrong = Color(hex: 0xDADADA)
    static let textSecondary = Color(hex: 0xA8A8A8)
    static let textTertiary = Color(hex: 0x949494)
    /// Dark text on a light fill (the primary button, Nook's accent).
    static let ink = Color(hex: 0x0B0B0D)

    /// Nook's own color: soft white, as on the Mac by default. Its text and symbols are `ink`.
    static let iris = Color(hex: 0xF4F3F7)
    static let onIris = ink
    static let mint = Color(hex: 0x5ED6A6)
    static let amber = Color(hex: 0xF2B866)
    static let coral = Color(hex: 0xEF7B73)
    static let violet = Color(hex: 0xAE94F2)
    /// Working, links, and the quote of someone else's message.
    static let blue = Color(hex: 0x8FB3F0)
    static let accent = blue
    /// Music playback accent.
    static let music = Color(hex: 0xF0936A)

    /// Chat app bubble colors (Mac's Chats tab palette).
    static let chatMine = Color(hex: 0x17493A)
    static let chatTheirs = Color(hex: 0x232525)
    static let chatStamp = Color(hex: 0xA3B0AB)

    // MARK: Type

    /// The type scale of the Mac (`NookTheme.TextStyle`), on the phone's Dynamic Type so it grows with the user's
    /// text size. A timestamp is `caption`; the line under a title `detail`; a badge or metadata `label`; what you read
    /// `body`; a row's title or a button `strong`; a card's title `title`; a sheet's heading `heading`; the one big
    /// line of a page `display`.
    enum TextStyle {
        static var caption: Font { .caption.weight(.medium) }
        static var detail: Font { .footnote }
        static var label: Font { .footnote.weight(.medium) }
        static var body: Font { .callout }
        static var strong: Font { .callout.weight(.semibold) }
        static var title: Font { .headline }
        static var heading: Font { .title3.weight(.semibold) }
        static var display: Font { .title.weight(.semibold) }
        /// A tab's own title in its `PanelHeader`.
        static var pageTitle: Font { .title2.weight(.semibold) }
        static var code: Font { .footnote.monospaced() }
    }

    /// A symbol's or a numeral's size that the scale does not cover.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// SF Rounded: only for a numeral in a badge or a count, never for running text.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // MARK: Shape and rhythm

    /// Corner radii, named after the element as on the Mac; a little rounder to suit the phone's own corners.
    enum Radius {
        /// Tags and inline code.
        static let chip: CGFloat = 6
        /// Buttons and fields.
        static let control: CGFloat = 8
        /// Cards and rows.
        static let card: CGFloat = 12
        /// Groups of rows and floating panels.
        static let panel: CGFloat = 16
        /// A message's bubble.
        static let bubble: CGFloat = 18
        /// A chat app's message bubble.
        static let chatBubble: CGFloat = 10
        /// Corner where two consecutive chat bubbles meet.
        static let chatJoin: CGFloat = 4
        /// The composer: a one-line box is a capsule.
        static let composer: CGFloat = 24
    }

    /// Spacing on the Mac's 4 pt grid (`NookTheme.Spacing`).
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        /// Between the sections of a page.
        static let xxxl: CGFloat = 32
    }

    /// The Mac's springs: open with a hint of overshoot, everything else settles without one.
    static let open = Animation.spring(duration: 0.42, bounce: 0.08)
    static let reveal = Animation.spring(duration: 0.24, bounce: 0)
    static let press = Animation.spring(duration: 0.2, bounce: 0)

    // MARK: Session state

    /// What a session's `attention` means, in a few words and a color (the Mac's `AgentStatusStyle`).
    static func color(_ attention: String) -> Color {
        switch attention {
        case "approval", "input", "limited": return amber
        case "failed": return coral
        case "working": return blue
        case "ready": return mint
        default: return textTertiary
        }
    }

    /// Approval, input, failure and a limit: what you have to act on.
    static func needsYou(_ attention: String) -> Bool {
        ["approval", "input", "failed", "limited"].contains(attention)
    }

    static func word(_ attention: String) -> String {
        switch attention {
        case "approval": return String(localized: "Waiting for approval")
        case "input": return String(localized: "Has a question")
        case "failed": return String(localized: "Failed")
        case "limited": return String(localized: "Limit reached")
        case "working": return String(localized: "Working")
        case "ready": return String(localized: "Ready")
        case "finished": return String(localized: "Finished")
        default: return String(localized: "Idle")
        }
    }

    static func symbol(_ attention: String) -> String {
        switch attention {
        case "approval": return "hand.raised.fill"
        case "input": return "questionmark.bubble.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "limited": return "hourglass"
        case "working": return "circle.dotted"
        case "ready": return "checkmark.circle.fill"
        case "finished": return "checkmark.circle"
        default: return "moon.zzz.fill"
        }
    }

    // MARK: Bars

    /// The navigation and tab bars styled as frosted dark glass matching the Mac's notch and expanded panels.
    static func applyBarAppearance() {
        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.backgroundColor = UIColor(canvas.opacity(0.85))
        navigation.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        navigation.shadowColor = UIColor(hairline)
        navigation.titleTextAttributes = [.foregroundColor: UIColor(text),
                                          .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(text),
                                               .font: UIFont.systemFont(ofSize: 28, weight: .bold)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation

        let item = UITabBarItemAppearance()
        for state in [item.normal, item.selected] {
            state.badgeBackgroundColor = UIColor(amber)
            state.badgeTextAttributes = [.foregroundColor: UIColor(ink), .font: UIFont.systemFont(ofSize: 11, weight: .semibold)]
        }
        item.normal.iconColor = UIColor(textTertiary)
        item.normal.titleTextAttributes = [.foregroundColor: UIColor(textTertiary)]
        item.selected.iconColor = UIColor(text)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(text)]

        let tabs = UITabBarAppearance()
        tabs.configureWithTransparentBackground()
        tabs.backgroundColor = UIColor(canvas.opacity(0.88))
        tabs.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        tabs.shadowColor = UIColor(hairline)
        tabs.stackedLayoutAppearance = item
        tabs.inlineLayoutAppearance = item
        tabs.compactInlineLayoutAppearance = item
        UITabBar.appearance().standardAppearance = tabs
        UITabBar.appearance().scrollEdgeAppearance = tabs

        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(raised)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Surfaces

extension View {
    /// A card on the canvas, the Mac's `panelCard`: a fill a step lighter than the canvas with subtle top specular stroke.
    /// With `tint` (something that waits on you, an error) it gets an ambient wash and a tinted edge.
    func card(padding: CGFloat = Theme.Spacing.xl, tint: Color? = nil) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Theme.surface
                    if let tint {
                        tint.opacity(0.04)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        AnyShapeStyle(
                            tint != nil
                                ? AnyShapeStyle(tint!.opacity(0.38))
                                : AnyShapeStyle(LinearGradient(
                                    colors: [Theme.text.opacity(0.08), Theme.text.opacity(0.015)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ))
                        ),
                        lineWidth: 1
                    )
            }
    }

    /// The dark canvas behind a whole screen, with matching bars.
    func screen() -> some View {
        self
            .background(Theme.canvas.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .toolbarBackground(Theme.canvas, for: .navigationBar)
    }
}

/// Rows that belong together in one card, split by `RowSeparator`s: the Mac's lists (Chats, For you).
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Theme.text.opacity(0.08), Theme.text.opacity(0.015)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
    }
}

/// The line between two rows of a `RowGroup`, inset to the rows' text.
struct RowSeparator: View {
    var inset: CGFloat = Theme.Spacing.xl

    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, inset).accessibilityHidden(true)
    }
}

/// A group's name above it ("Needs you", "For you"): small and quiet, never uppercase, as `NookSectionLabel`. A count
/// of what waits for you follows as a `CountBadge`.
struct SectionHeader: View {
    let title: LocalizedStringKey
    var count: Int? = nil
    /// Amber count for what waits on you; otherwise the count is a quiet number.
    var urgent = false

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.TextStyle.label)
                .foregroundStyle(urgent ? Theme.amber : Theme.textTertiary)
            if let count {
                if urgent {
                    CountBadge(count: count)
                } else {
                    Text(count, format: .number).font(Theme.TextStyle.caption).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.xxs)
        .accessibilityAddTraits(.isHeader)
    }
}

/// How many wait for you: amber numerals on a faint wash, the Mac's `NookCountBadge`. Zero shows nothing.
struct CountBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count, format: .number)
                .font(Theme.rounded(11.5, .semibold)).monospacedDigit()
                .foregroundStyle(Theme.amber)
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(minWidth: 20, minHeight: 20)
                .background(Theme.amber.opacity(0.16), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.amber.opacity(0.28), lineWidth: 0.5))
        }
    }
}

/// A session's state as a mark and a word, the Mac's `AgentStatusBadge`: only the mark carries the color; the word is
/// grey, and paper-white when the session waits on you. The mark pulses while the agent works.
struct StatusPill: View {
    let attention: String

    var body: some View {
        let color = Theme.color(attention)
        let needs = Theme.needsYou(attention)
        HStack(spacing: Theme.Spacing.xs) {
            if attention == "working" {
                PulseDot(color: color, size: 6)
            } else {
                Image(systemName: Theme.symbol(attention))
                    .font(Theme.font(10.5, .semibold))
                    .foregroundStyle(color)
            }
            Text(Theme.word(attention))
                .font(Theme.TextStyle.label)
                .foregroundStyle(needs ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.sm + 1)
        .padding(.vertical, 3)
        .background(color.opacity(needs ? 0.12 : 0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(needs ? 0.28 : 0.14), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// A live dot that breathes with an ambient radar ring, for work in progress; still with Reduce Motion.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(on ? 1.9 : 1.0)
                    .opacity(on ? 0 : 0.45)
            }
            Circle().fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: 12, height: 12)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) { on = true }
        }
    }
}

/// Nook himself, as on the Mac: a round pearl lit like a ball (highlight top left, ambient bounce below, soft iris glow),
/// with expressive eyes that breathe and blink, and playful squish on tap.
struct NookMark: View {
    var size: CGFloat = 32

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var blinking = false
    @State private var squishing = false

    var body: some View {
        ZStack {
            // Ambient soft glow
            Circle()
                .fill(Theme.iris.opacity(0.18))
                .frame(width: size * 1.1, height: size * 1.1)
                .blur(radius: size * 0.12)

            // Sphere base with specular highlight top-left and soft shadow bottom-right
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, Theme.iris, Color(hex: 0xCAC8D2), Color(hex: 0x8C8B96)],
                        center: UnitPoint(x: 0.34, y: 0.26),
                        startRadius: 0,
                        endRadius: size * 0.65
                    )
                )

            // Ambient lower bounce light
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.22)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // Nook's soulful eyes with delicate catchlights
            HStack(spacing: size * 0.16) {
                eye
                eye
            }
            .offset(y: -size * 0.02)
            .scaleEffect(y: blinking ? 0.08 : 1, anchor: .center)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.iris.opacity(0.22), radius: size * 0.16, y: 1)
        .scaleEffect(
            x: squishing ? 1.14 : (breathing && !reduceMotion ? 1.015 : 0.985),
            y: squishing ? 0.86 : (breathing && !reduceMotion ? 0.985 : 1.015)
        )
        .contentShape(Circle())
        .onTapGesture { squish() }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathing = true
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Double.random(in: 3.5...5.5)))
                guard !reduceMotion else { continue }
                withAnimation(.easeInOut(duration: 0.1)) { blinking = true }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { blinking = false }
            }
        }
        .accessibilityHidden(true)
    }

    private var eye: some View {
        ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Theme.ink)
                .frame(width: size * 0.095, height: size * 0.22)
            // Tiny eye shine
            Circle()
                .fill(Color.white.opacity(0.85))
                .frame(width: size * 0.035, height: size * 0.035)
                .offset(x: size * 0.015, y: size * 0.025)
        }
    }

    private func squish() {
        Haptics.tap()
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
            squishing = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) {
                squishing = false
            }
        }
    }
}

/// A short notice across the width of the screen: offline, push not ready, no brain. It stands on `surface`; only its
/// symbol carries the state color.
struct Banner: View {
    let text: String
    let symbol: String
    var color: Color = Theme.amber

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).foregroundStyle(Theme.textStrong).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Theme.TextStyle.detail)
        .card(padding: Theme.Spacing.lg, tint: color.opacity(0.3))
    }
}

/// An empty screen: a symbol, what it means, and what to do next.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: symbol)
                .font(Theme.font(26, .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 64, height: 64)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Theme.text.opacity(0.08), Theme.text.opacity(0.015)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            VStack(spacing: Theme.Spacing.sm) {
                Text(title).font(Theme.TextStyle.heading).foregroundStyle(Theme.text)
                Text(message).font(Theme.TextStyle.body).foregroundStyle(Theme.textSecondary).multilineTextAlignment(.center)
            }
            actions.padding(.top, Theme.Spacing.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, Theme.Spacing.xxl)
    }
}

// MARK: Buttons

/// The one main action of a screen: a full-width paper capsule with ink text, the Mac's `NookPrimaryButton`.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.TextStyle.strong)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                LinearGradient(
                    colors: configuration.isPressed
                        ? [Color.white, Color(hex: 0xEDEDF2)]
                        : [Color(hex: 0xFCFCFE), Color(hex: 0xE6E5EC)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.5)
            )
            .shadow(color: Color.white.opacity(configuration.isPressed ? 0.05 : 0.14), radius: 8, y: 2)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// A compact action on a card (Allow, Deny, an answer): `filled` is the main one in paper, the rest a quiet grey with
/// paper text. `color` tints only the text of a quiet one (Deny in coral).
struct ActionButtonStyle: ButtonStyle {
    var color: Color = Theme.text
    var filled = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.TextStyle.strong)
            .foregroundStyle(filled ? Theme.ink : color)
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity)
            .background {
                (filled
                    ? LinearGradient(
                        colors: configuration.isPressed
                            ? [Color.white, Color(hex: 0xEDEDF2)]
                            : [Color(hex: 0xFCFCFE), Color(hex: 0xE6E5EC)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    : LinearGradient(
                        colors: [Theme.raised, Theme.surface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .clipShape(Capsule())
            }
            .overlay(
                Capsule().strokeBorder(
                    filled ? Color.white.opacity(0.5) : Theme.text.opacity(0.08),
                    lineWidth: 0.5
                )
            )
            .opacity(isEnabled ? (configuration.isPressed && !filled ? 0.7 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

/// A round symbol button in a screen's bar or a card: quiet grey, as the Mac's `NookIconButton`.
struct IconButtonLabel: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(Theme.font(15, .semibold))
            .foregroundStyle(Theme.text)
            .frame(width: 36, height: 36)
            .background(Theme.raised, in: Circle())
            .overlay(
                Circle().strokeBorder(
                    LinearGradient(colors: [Theme.text.opacity(0.1), Theme.text.opacity(0.02)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            )
    }
}

/// One chip in a row of filters ("All", "Unread"): a quiet capsule, filled with paper when chosen, the Mac's
/// `NookFilterChip`.
struct FilterChip: View {
    let title: LocalizedStringKey
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title).font(Theme.TextStyle.label)
                if let count, count > 0 {
                    Text(count, format: .number).font(Theme.rounded(11.5, .medium)).monospacedDigit().opacity(selected ? 0.8 : 0.6)
                }
            }
            .foregroundStyle(selected ? Theme.ink : Theme.textStrong)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(minHeight: 32)
            .background {
                (selected
                    ? LinearGradient(colors: [Color.white, Color(hex: 0xEDEDF2)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Theme.raised, Theme.surface], startPoint: .top, endPoint: .bottom)
                )
                .clipShape(Capsule())
            }
            .overlay(
                Capsule().strokeBorder(
                    selected ? Color.white.opacity(0.5) : Theme.text.opacity(0.08),
                    lineWidth: 0.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Theme.reveal, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A choice among a few: an agent or a folder in the new-session sheet.
struct ChoiceChip: View {
    let title: String
    var detail: String? = nil
    let selected: Bool
    var icon: AnyView? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.lg) {
                if let icon { icon }
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).font(Theme.TextStyle.strong).foregroundStyle(Theme.text)
                    if let detail { Text(detail).font(Theme.TextStyle.detail).foregroundStyle(Theme.textTertiary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(Theme.font(19))
                    .foregroundStyle(selected ? Theme.iris : Theme.textTertiary)
            }
            .padding(Theme.Spacing.lg)
            .background(selected ? Theme.raised : Theme.surface,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        AnyShapeStyle(
                            selected
                                ? AnyShapeStyle(Theme.iris.opacity(0.35))
                                : AnyShapeStyle(LinearGradient(colors: [Theme.text.opacity(0.08), Theme.text.opacity(0.015)], startPoint: .top, endPoint: .bottom))
                        ),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A light tap for what you just did from the phone.
enum Haptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}
