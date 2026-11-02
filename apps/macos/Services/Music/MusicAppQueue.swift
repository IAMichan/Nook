import Foundation
import AppKit
import ApplicationServices

/// Puts a track in Music's own queue. Music's AppleScript has no command for that, so Nook selects the track in Music
/// (`reveal`) and presses Music's own Song › Add to Queue menu item through Accessibility, found by the title Music
/// shows in its own language. Runs on `NowPlayingService.libraryQueue`. `false` when any step fails (no Accessibility
/// permission, the track is not in Music's library or the current playlist, the menu item is missing or disabled):
/// the caller then keeps the track in Nook's own queue.
enum MusicAppQueue {
    private static let bundleID = "com.apple.Music"

    static func add(persistentID id: String) -> Bool {
        guard NowPlayingService.isPersistentID(id), AXIsProcessTrusted(),
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        let quoted = MusicScriptOutput.quoted(id)
        // From the playlist that plays when the track is in it, from the library otherwise.
        let reveal = NowPlayingService.runPlayerScript("""
        with timeout of 4 seconds
        tell application "Music"
            try
                reveal (first track of current playlist whose persistent ID is \(quoted))
            on error
                reveal (first track of library playlist 1 whose persistent ID is \(quoted))
            end try
        end tell
        end timeout
        """)
        guard reveal.errorNumber == nil else { return false }
        // The menu enables the item once Music has the selection.
        Thread.sleep(forTimeInterval: 0.25)
        guard let item = menuItem(in: AXUIElementCreateApplication(app.processIdentifier), titled: addToQueueTitles()) else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// "Add to Queue" in the language Music runs in, and in English.
    static func addToQueueTitles() -> Set<String> {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) else {
            return ["Add to Queue"]
        }
        let languages = CFPreferencesCopyAppValue("AppleLanguages" as CFString, bundleID as CFString) as? [String] ?? Locale.preferredLanguages
        var titles: Set<String> = ["Add to Queue"]
        for language in Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: languages) + ["en"] {
            if let path = bundle.path(forResource: "UserInterface", ofType: "strings", inDirectory: nil, forLocalization: language),
               let table = NSDictionary(contentsOfFile: path), let title = table["PLAY_LATER_MENU_ITEM"] as? String {
                titles.insert(title)
            }
        }
        return titles
    }

    /// The first enabled item with one of `titles` in the app's menu bar menus.
    private static func menuItem(in app: AXUIElement, titled titles: Set<String>) -> AXUIElement? {
        guard let bar = value(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return nil }
        for top in children(bar) {
            for menu in children(top) {
                for item in children(menu) {
                    guard let title = value(item, kAXTitleAttribute) as? String, titles.contains(title) else { continue }
                    if (value(item, kAXEnabledAttribute) as? Bool) == true { return item }
                }
            }
        }
        return nil
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
