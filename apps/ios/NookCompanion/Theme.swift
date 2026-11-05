import SwiftUI
import UIKit

// The companion's design is Nook's own: `NookTheme` (apps/macos/NotchUI/Theme/NookTheme.swift) is compiled into this app
// and its Live Activity, and is called `Theme` here. Its colors, radii, spacing and motion are the Mac's exactly; its
// type scale is the Mac's a step larger and on Dynamic Type (`NookTheme.textFont`). What is only the phone's is here: how
// a session's state reads in words, and the system bars. Change the design in `NookTheme`, never here.
typealias Theme = NookTheme

extension NookTheme.TextStyle {
    /// A tab in the panel's header, as the Mac's `NookTabBar`.
    static var tab: Font { NookTheme.textFont(13, .medium) }
}

extension NookTheme {
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

    /// One word for a row's corner, where the row's title says the rest.
    static func shortWord(_ attention: String) -> String {
        switch attention {
        case "approval": return String(localized: "Approval")
        case "input": return String(localized: "Question")
        case "failed": return String(localized: "Failed")
        case "limited": return String(localized: "Limit")
        case "working": return String(localized: "Working")
        case "ready": return String(localized: "Done")
        default: return word(attention)
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
        navigation.titleTextAttributes = [.foregroundColor: UIColor(paper),
                                          .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(paper),
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
