import SwiftUI

// The components in NotchUI/Shared are compiled into both apps: Nook on the Mac and Nook Companion on the iPhone
// (apps/ios/project.yml). They take everything from `NookTheme` (the iPhone's `Theme` under the same name) and differ
// per platform only where the platform asks for it: the pointer and hover on the Mac, touch and Dynamic Type on the
// phone. Change one here and both apps follow.

/// A text of a shared component in the app's language: the Mac's `tr` key, or the iPhone's string catalog, where the
/// English text is the key.
func sharedText(_ key: String, _ english: String.LocalizationValue) -> String {
    #if os(macOS)
    tr(key)
    #else
    String(localized: english)
    #endif
}

/// The size of a shared component's parts per platform: the Mac's pointer-sized ones, larger targets for a finger.
enum SharedMetrics {
    #if os(macOS)
    static let isPhone = false
    #else
    static let isPhone = true
    #endif

    /// The face in front of a chat in a list.
    static let avatar: CGFloat = 40
    /// Room around a row of a list: a finger needs a taller row than a pointer.
    static let rowVertical: CGFloat = isPhone ? NookTheme.Spacing.lg : NookTheme.Spacing.md
}
