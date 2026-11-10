import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// One theme for both apps: Nook on the Mac and Nook Companion on the iPhone (apps/ios/project.yml compiles this file
// too, as `Theme` there). The only differences are where a platform asks for one: the phone's type follows Dynamic Type
// (`TextStyle`), and the Mac's own window transitions stay on the Mac.

extension Color {
    /// Creates a color from a hex integer, e.g. `Color(hex: 0x8B7BFF)`.
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }

    /// A color written as six hex digits, with or without "#" ("d73a4a", as GitHub gives a label's color); nil when the
    /// text is not one. For colors that come with the data, never for Nook's own palette.
    init?(hexString text: String?) {
        guard var text = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

/// Nook design system. Color consistently represents state:
/// iris = Nook itself, mint = listening or done, amber = waiting on you, coral = error.
///
/// Calm by design: every surface sits on one neutral grey ramp, a step apart, so regions read by their fill and need
/// almost no strokes; strokes are only a shade lighter than what they edge; state colors are a little softened so a
/// badge informs without shouting. Change a token here and every panel, card and setting follows.
///
/// The ramp is pure grey (no blue cast): a near-black canvas (#0A0A0A), raised
/// surfaces about 4–8 % lighter, separation by tonal steps and 4–8 % white fills instead of grey panels or heavy lines.
/// Color is kept for state (a status mark and its word, errors, diff +/−) and for links; everything else is neutral.
///
/// Clear before calm: every text color reads at WCAG AA (4.5:1 or more) on every surface up to `smoke`, so even the
/// quietest metadata (`textTertiary`) is legible at a glance, and a selected row stands a full step above a hovered one,
/// so where you are never depends on a shade you can barely see.
enum NookTheme {
    // The palettes in effect: the chosen theme's for dark and for light (`NookThemeChoice`, kept in sync by
    // `AppSettings`). Every named color below reads them when it is drawn, in the appearance of the window it is drawn
    // in, so a view that takes its colors from here follows System / Light / Dark and the theme without knowing either.
    nonisolated(unsafe) static var darkPalette = NookPalette.nookDark
    nonisolated(unsafe) static var lightPalette = NookPalette.nookLight
    /// Goes up whenever a palette changes, so caches of drawn text (`SelectableProse`) and the roots that rebuild on a
    /// change (`.id`) can key on it.
    nonisolated(unsafe) static var revision = 0

    static func palette(dark: Bool) -> NookPalette { dark ? darkPalette : lightPalette }

    /// Sets the palettes; true when something changed.
    @discardableResult
    static func apply(dark: NookPalette, light: NookPalette) -> Bool {
        guard dark != darkPalette || light != lightPalette else { return false }
        darkPalette = dark
        lightPalette = light
        revision += 1
        return true
    }

    /// A color of the palette in effect, resolved for the appearance it is drawn in.
    static func themed(_ token: KeyPath<NookPalette, UInt32>) -> Color {
        adaptive { palette(dark: $0)[keyPath: token] }
    }

    /// A color that is worked out per appearance (dark true or false) each time it is drawn.
    static func adaptive(_ hex: @escaping (Bool) -> UInt32) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            platformColor(hex(appearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua))
        })
        #else
        Color(uiColor: UIColor { traits in platformColor(hex(traits.userInterfaceStyle != .light)) })
        #endif
    }

    #if os(macOS)
    static func platformColor(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    #else
    static func platformColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    #endif

    // Colors: the surface ramp, darkest to lightest.
    /// The notch itself: always black, in every theme, as the hardware it grows out of. Also the color of shadows.
    static let notch = Color.black
    static let graphite = themed(\.graphite)
    static let smoke = themed(\.smoke)
    static let field = themed(\.field)
    static let line = themed(\.line)
    static let line2 = themed(\.line2)

    /// The strongest text: near white on dark, near black on light.
    static let paper = themed(\.paper)
    /// Dark ink, in every appearance: text on a light fill (a light accent) and the scrim over pictures and video.
    static let ink = Color(hex: 0x0B0B0D)
    static let eyeInk = Color(hex: 0x050507)
    static let textSecondary = themed(\.textSecondary)
    static let textTertiary = themed(\.textTertiary)
    /// A `paper` fill (Nook's main button) and the text on it: `onPaper` is dark on dark windows, white on light ones.
    static let onPaper = adaptive { $0 ? 0x0B0B0D : 0xFFFFFF }
    /// `paper` under the pointer: a step brighter on dark, a step deeper on light.
    static let paperHover = adaptive { $0 ? 0xFFFFFF : 0x000000 }
    /// The color of a faint wash over a surface (`wash.opacity(0.06)`): white on dark, black on light, so a hover or a
    /// hairline made of it shows in both.
    static let wash = adaptive { $0 ? 0xFFFFFF : 0x000000 }

    /// Nook's own color. Soft white by default (near black in light); the user can pick another in Settings › Appearance.
    static let defaultAccentHex: UInt32 = 0xF4F3F7
    /// Current accent (kept in sync by `AppSettings.accentHex`).
    nonisolated(unsafe) static var accentHex: UInt32 = defaultAccentHex
    /// The accent as drawn: the user's color, or the theme's own when they kept the default.
    static func accent(dark: Bool) -> UInt32 {
        accentHex == defaultAccentHex ? palette(dark: dark).accent : accentHex
    }
    static let iris = adaptive { accent(dark: $0) }
    /// Text and symbols on an iris fill: dark on a light accent (the default soft white), white on a deep one.
    static let onIris = adaptive { relativeLuminance(accent(dark: $0)) > 0.45 ? 0x0B0B0D : 0xFFFFFF }

    /// WCAG relative luminance of a 0xRRGGBB color, 0 (black) to 1 (white).
    static func relativeLuminance(_ hex: UInt32) -> Double { NookColor.luminance(hex) }
    static let mint = themed(\.mint)
    static let amber = themed(\.amber)
    static let coral = themed(\.coral)
    static let coralSoft = themed(\.coralSoft)
    /// A merged pull request, as forges show it.
    static let violet = themed(\.violet)
    static let mintSoft = themed(\.mintSoft)
    static let music = themed(\.music)

    /// The canvas behind every window: the Workspace, Settings, and the Today window share it. Pure black in Nook's dark
    /// theme, as the notch, so cards and borders carry the structure.
    static let canvas = themed(\.canvas)
    /// A sunken well inside a card: code, logs, and the composer tray.
    static let well = themed(\.well)
    /// A lifted surface: sidebars, menus, the composer.
    static let surface = themed(\.surface)
    /// The faintest divider between regions of a panel.
    static let hairline = themed(\.hairline)
    /// The line between a window's columns and panels (the sidebar, the side panel, a pane's header): a hairline that
    /// is there when you look for it and gone when you don't, so regions read by their layout rather than their frames.
    static let border = themed(\.border)
    /// The line between the items of a list (a chat in the Chats tab): a step brighter than `border`, so
    /// each item reads as its own.
    static let separator = themed(\.separator)
    /// The stroke of a text field or tray at rest.
    static let fieldStroke = themed(\.fieldStroke)
    /// Body text that reads a little softer than `paper`, without dropping to `textSecondary`.
    static let textStrong = themed(\.textStrong)
    /// Muted text that shimmers or sits in a disabled control.
    static let textMuted = themed(\.textMuted)
    /// Links, renamed files, and diff hunk headers.
    static let blue = themed(\.blue)

    /// Your own message in a conversation: a soft fill a step off the canvas, no edge (the agent's answer has no bubble
    /// at all).
    static let bubble = themed(\.bubble)
    /// A chat app's message bubbles in the Chats tab and chat cards: yours a deep green of Nook's mint, theirs a grey a
    /// step above the canvas. Solid, so who said what reads at a glance, as in the chat apps themselves.
    static let chatMine = themed(\.chatMine)
    static let chatTheirs = themed(\.chatTheirs)
    /// The time and grey ticks inside those bubbles: soft, yet readable on both fills.
    static let chatStamp = themed(\.chatStamp)

    /// Syntax colors for code in diffs (`SyntaxToken.Kind`). Muted on purpose: the diff's own + and − tints stay the
    /// loudest thing, and plain code keeps `textStrong`. Each has a dark and a light value, picked by the appearance of the
    /// window they are drawn in (Settings › Appearance).
    enum Syntax {
        static let keyword = adaptive(dark: 0xC3A6EE, light: 0x7A45B5)
        static let string = adaptive(dark: 0xA8CF96, light: 0x3D7A2E)
        static let comment = adaptive(dark: 0x6F7378, light: 0x8A8F96)
        static let number = adaptive(dark: 0xE6B98A, light: 0x9A5A12)
        static let type = adaptive(dark: 0x8EC7E3, light: 0x1D6E93)
        static let property = adaptive(dark: 0xA3BCEB, light: 0x3B5DA6)
        static let tag = adaptive(dark: 0xE79BB8, light: 0xA33A6C)
        static let attribute = adaptive(dark: 0xD9C27E, light: 0x86690F)

        private static func adaptive(dark: UInt32, light: UInt32) -> Color {
            NookTheme.adaptive { $0 ? dark : light }
        }
    }

    // List rows and cards: at rest, under the pointer, and selected.
    static let rowRest = themed(\.rowRest)
    static let rowHover = themed(\.rowHover)
    static let rowSelected = themed(\.rowSelected)

    /// The fill of a list row: `rowSelected` when selected, `rowHover` under the pointer, `rest` otherwise.
    static func rowFill(selected: Bool, hovering: Bool, rest: Color = rowRest) -> Color {
        selected ? rowSelected : (hovering ? rowHover : rest)
    }

    /// Corner radii. Pick the token that names the element, not the number: a chip inside a card is always rounder
    /// than a hairline and flatter than the card.
    enum Radius {
        /// Tags, keycaps, and inline code.
        static let chip: CGFloat = 6
        /// Buttons, text fields, and toolbar items.
        static let control: CGFloat = 8
        /// Cards, rows, and notices.
        static let card: CGFloat = 10
        /// Panels, popovers, and menus.
        static let panel: CGFloat = 12
        /// Sheets and the composer tray.
        static let sheet: CGFloat = 14
        /// Your own message's bubble in a conversation.
        static let bubble: CGFloat = 16
        /// A chat app's message bubble: tighter than Nook's own, so long runs of messages stay compact.
        static let chatBubble: CGFloat = 10
        /// Where two bubbles of one run meet, on the writer's side: a small rounding, so the run stacks as one column.
        static let chatJoin: CGFloat = 4
        /// A card in a conversation: a plan, a question, a task list, a subagent.
        static let conversationCard: CGFloat = 16
        /// Pills and the notch's own corners.
        static let pill: CGFloat = 20
        /// The composer box, and the tray that runs on from it. With the 32 pt send button 8 pt from the edge, its corner
        /// runs parallel to the button's.
        static let composer: CGFloat = 16
    }

    /// Spacing on a 4 pt grid. Use these for padding and stack spacing so the panels line up.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 24
        /// Between the sections of a page (home, a settings page): room that groups without a line.
        static let xxxl: CGFloat = 32
    }

    /// The type scale: each kind of text with its size and weight, so two panels never show the same kind of text at
    /// different sizes. Running text is a `TextStyle`; use `font(_:_:)` only for a symbol's size or a numeral the scale
    /// does not cover. The sizes follow t3code: what you read is 14 pt (its `text-sm`), the dense UI around it 12 pt
    /// (`text-xs`), badges 11.5 and the smallest metadata 10.5, so reading text stands a clear step above the chrome.
    ///
    /// Picking one: a timestamp or a count is `caption`; the line under a title (a hint, a setting's explanation, a
    /// row's second line) is `detail`; a badge, a chip or metadata is `label`; what you read is `body`; a row's title
    /// or a button is `strong`; a panel's or card's title is `title`; a sheet's or a step's heading is `heading`; the one
    /// big line on a page (home's greeting, a settings page) is `display`.
    enum TextStyle {
        /// Timestamps, counts, and the smallest metadata.
        static var caption: Font { NookTheme.textFont(10.5, .medium) }
        /// The line under a title: a setting's explanation, a hint, a row's second line, or an error message.
        static var detail: Font { NookTheme.textFont(12) }
        /// Secondary labels, badges, chips, and metadata.
        static var label: Font { NookTheme.textFont(11.5, .medium) }
        /// Body text in rows, cards, chat, and the composer.
        static var body: Font { NookTheme.textFont(14) }
        /// A composer's choices (model, mode, access): a step under `strong`, so they fit a narrow box.
        static var control: Font { NookTheme.textFont(13, .medium) }
        /// A row title or a button: medium rather than bold, so a list of titles stays calm and the text carries it.
        static var strong: Font { NookTheme.textFont(14, .medium) }
        /// The title of a panel, a list, or a card.
        static var title: Font { NookTheme.textFont(15, .semibold) }
        /// The heading of a sheet or a setup step.
        static var heading: Font { NookTheme.textFont(18, .semibold) }
        /// The one large line of a page: home's greeting, a settings page's title.
        static var display: Font { NookTheme.textFont(22, .semibold) }
        /// Inline code and paths at body size.
        static var code: Font { NookTheme.textFont(13, design: .monospaced) }
    }

    /// How much larger text is on the phone than on the Mac at the same place in the scale: the Mac's 14 pt body is the
    /// phone's 16 pt (`.callout`), held further from the eye.
    static let phoneTextScale: CGFloat = 16.0 / 14.0

    /// A size of the type scale: as written on the Mac; on the phone a step larger and following the text size you chose
    /// (Dynamic Type), so the two apps keep the same proportions.
    static func textFont(_ size: CGFloat, _ weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        #if os(macOS)
        .system(size: size, weight: weight, design: design)
        #else
        .system(size: UIFontMetrics.default.scaledValue(for: size * phoneTextScale), weight: weight, design: design)
        #endif
    }

    // Typography: SF Pro for text, SF Mono for code and paths.
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// SF Rounded: only for a numeral in a badge or a step counter, never for running text.
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    // Animation. Every curve is a spring: a spring keeps its velocity when it is interrupted (hover off before the
    // hover in finished, a tab picked while the last one still slides), where a timing curve restarts from rest and
    // visibly jerks. Opening has a subtle overshoot; closing is smooth without bounce.
    static let open = Animation.spring(duration: 0.36, bounce: 0.06)
    static let close = Animation.spring(duration: 0.3, bounce: 0)
    /// Tab switching within the same panel: tighter, and without overshoot so the content does not wobble.
    static let swap = Animation.spring(duration: 0.28, bounce: 0)
    /// The new tab's content fading in once you switch: short, so the tab is there almost at once.
    static let tabFade = Animation.easeOut(duration: 0.14)
    /// How long a tab waits before work that redraws the whole app (a refresh on opening it), so the switch is over first.
    static let tabSettle: Duration = .milliseconds(320)
    /// Hover feedback on buttons and chips: quick and settled.
    static let hover = Animation.spring(duration: 0.2, bounce: 0)
    /// Showing or hiding part of a panel: a section that expands, a preview or side panel, a selection that changes.
    static let reveal = Animation.spring(duration: 0.24, bounce: 0)
    /// Scrolling a list to a message or a line.
    static let scroll = Animation.spring(duration: 0.3, bounce: 0)
    static let spring = open
}

/// Lifts a control a hair while the pointer is on it (see `View.hoverLift`). With Reduce Motion on it stays put: the
/// color change alone says that it is live.
private struct HoverLift: ViewModifier {
    var hovering: Bool
    var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? scale : 1)
            .animation(NookTheme.hover, value: hovering)
    }
}

extension View {
    /// The shared hover state of Nook's buttons and chips: a slight lift with `NookTheme.hover`, none with Reduce Motion.
    func hoverLift(_ hovering: Bool, scale: CGFloat = 1.01) -> some View {
        modifier(HoverLift(hovering: hovering, scale: scale))
    }
}

/// Notch content: appears slightly after the shape (snappy fade-in) and dismisses quickly.
/// Opacity and scale only: both are composited as they are, where a blur renders the whole panel offscreen again on
/// every frame of the opening, which is where it stuttered.
private struct NotchContentFade: ViewModifier {
    var amount: CGFloat   // 1 = gone, 0 = visible
    func body(content: Content) -> some View {
        content
            .opacity(1 - Double(amount))
            .scaleEffect(1 - amount * 0.03, anchor: .top)
            .offset(y: -amount * 4)
    }
}

#if os(macOS)
extension AnyTransition {
    static var notchContent: AnyTransition {
        // Reduce Motion: a plain fade, without the blur and the scale.
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            return .asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.09)),
                               removal: .opacity.animation(.easeIn(duration: 0.12)))
        }
        return .asymmetric(
            insertion: .modifier(active: NotchContentFade(amount: 1), identity: NotchContentFade(amount: 0))
                .animation(.spring(duration: 0.28, bounce: 0).delay(0.04)),
            removal: .opacity.animation(.spring(duration: 0.14, bounce: 0))
        )
    }
}
#endif

#if os(macOS)
/// Nook's windows and Settings › Appearance: the appearance they take (System / Light / Dark) and the theme's palettes.
/// The notch is not one of them: it grows out of the black hardware notch, so it stays dark in every theme.
@MainActor
enum NookWindowLook {
    /// The mode in effect (kept in sync by `AppSettings.appearanceMode`).
    static var mode: NookAppearanceMode = .dark

    /// The appearance a window of Nook takes: nil follows macOS.
    static var appearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// The canvas as an AppKit color, for a window's own background behind its content.
    static let canvas = NSColor(name: nil) { appearance in
        NookTheme.platformColor(NookTheme.palette(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua).canvas)
    }

    private static let adopted = NSHashTable<NSWindow>.weakObjects()

    /// Gives a window Nook's appearance and canvas, now and whenever they change. Sheets and popovers presented from it
    /// inherit the appearance, so they follow too.
    static func adopt(_ window: NSWindow, background: Bool = true) {
        window.appearance = appearance
        if background { window.backgroundColor = canvas }
        adopted.add(window)
    }

    /// After a change of mode or palette: every adopted window takes the appearance again, which redraws its colors
    /// (a dynamic color is resolved again when the appearance is set, also to the same one).
    static func refresh() {
        for window in adopted.allObjects {
            window.appearance = window.appearance === appearance ? nil : window.appearance
            window.appearance = appearance
            window.contentView?.needsDisplay = true
            window.invalidateShadow()
        }
    }

    /// Whether macOS itself is dark right now (for the preview of System).
    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
#endif
