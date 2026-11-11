import SwiftUI
import UIKit

// The companion's design is Nook's own: `NookTheme` (apps/macos/NotchUI/Theme/NookTheme.swift) is compiled into this app
// and its Live Activity, and is called `Theme` here. Its radii, spacing and motion are the Mac's; its type scale is the
// Mac's a step larger, on Dynamic Type and in DM Sans (`NookTheme.textFont`). What is only the phone's is here: its
// palette (iPhone app, `NookPalette.companionDark`), how a session's state reads in words and color, its
// shapes (`PhoneRadius`), and the system bars.
typealias Theme = NookTheme

extension NookPalette {
    /// The phone's dark look iPhone app (apps/mobile, its default dark theme): a near-black screen
    /// (#0a0a0a) instead of the Mac's true black, cards a step above it (#111111), grouped sections (#1a1b1b) and lines of
    /// #191919; blue for links and the selected tab. Every other value is Nook's own dark palette, so the text
    /// keeps its contrast (`textTokens` on `readingSurfaces`) and state keeps its colors.
    static let companionDark: NookPalette = {
        var palette = NookPalette.nookDark
        palette.canvas = 0x0A0A0A
        palette.well = 0x0A0A0A
        palette.surface = 0x111111
        palette.field = 0x111111
        palette.graphite = 0x1A1B1B
        palette.smoke = 0x262626
        palette.rowRest = 0x0A0A0A
        palette.rowHover = 0x141414
        palette.rowSelected = 0x1A1B1B
        palette.bubble = 0x161616
        palette.chatTheirs = 0x1A1B1B
        palette.line = 0x191919
        palette.line2 = 0x262626
        palette.hairline = 0x191919
        palette.border = 0x191919
        palette.separator = 0x191919
        palette.fieldStroke = 0x1E1E1E
        palette.blue = 0x4B7CF3
        palette.accent = 0xF5F5F5
        return palette
    }()
}

extension NookTheme.TextStyle {
    /// A section's name above its rows: small, bold and in capitals with wide spacing, section label.
    static var section: Font { NookTheme.textFont(10.5, .bold) }
    /// A row's title in a list: 16 pt medium.
    static var rowTitle: Font { NookTheme.textFont(14, .medium) }
}

/// The phone's shapes iPhone app: rounder than the Mac's, as touch and a phone's own corners ask. The Mac
/// keeps `NookTheme.Radius`.
enum PhoneRadius {
    /// A row lit under your finger.
    static let row: CGFloat = 12
    /// A card: what waits on you, a notice.
    static let card: CGFloat = 20
    /// A grouped section of rows (Today, a sheet's choices).
    static let group: CGFloat = 24
    /// The composer and the field you type in.
    static let composer: CGFloat = 27
    /// Floating glass: the tab bar.
    static let glass: CGFloat = 32
}

extension NookTheme {
    // MARK: The phone's look

    /// Puts the phone's palette in place (`NookPalette.companionDark`); called first thing by the app and its extensions,
    /// before anything is drawn.
    static func applyPhoneLook() {
        apply(dark: .companionDark, light: .nookLight)
    }

    /// Work in progress, sky (sky-400 on dark, sky-600 on light).
    static let sky = adaptive { $0 ? 0x00BCFF : 0x0084D1 }
    /// A question for you, indigo for "Input" (indigo-300 on dark, indigo-600 on light).
    static let indigo = adaptive { $0 ? 0xA3B3FF : 0x4F39F6 }

    // MARK: Session state

    /// What a session's `attention` means, in a few words and a color (the Mac's `AgentStatusStyle`), with 
    /// colors for its states: amber for an approval or a limit, indigo for a question, sky while it works.
    static func color(_ attention: String) -> Color {
        switch attention {
        case "approval", "limited": return amber
        case "input": return indigo
        case "failed": return coral
        case "working": return sky
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

    /// One word for a row's corner, where the row's title says the rest.
    static func shortWord(_ attention: String) -> String {
        switch attention {
        case "approval": return String(localized: "Approval")
        case "input": return String(localized: "Input")
        case "failed": return String(localized: "Failed")
        case "limited": return String(localized: "Limit")
        case "working": return String(localized: "Working")
        case "ready": return String(localized: "Done")
        default: return word(attention)
        }
    }

    static func symbol(_ attention: String) -> String {
        switch attention {
        case "approval": return "exclamationmark.shield.fill"
        case "input": return "questionmark.bubble.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "limited": return "hourglass"
        case "working": return "circle.dashed"
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
        navigation.titleTextAttributes = [.foregroundColor: UIColor(paper),
                                          .font: UIFont(name: "DMSans-Bold", size: 17) ?? UIFont.systemFont(ofSize: 17, weight: .semibold)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(paper),
                                               .font: UIFont(name: "DMSans-Bold", size: 28) ?? UIFont.systemFont(ofSize: 28, weight: .bold)]
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
        item.selected.iconColor = UIColor(paper)
        item.selected.titleTextAttributes = [.foregroundColor: UIColor(paper)]

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

        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(smoke)
    }
}
