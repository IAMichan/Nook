import SwiftUI
import UIKit

/// The quick actions on the app's icon (touch and hold it on the Home Screen): start a session, ask Nook, open your chats, and jump straight into the sessions that need you or ran
/// last. A tap lands in `CompanionClient.pendingShortcut`, which `RootView` acts on.
enum AppShortcut: Equatable {
    case newSession
    case askNook
    case chats
    case session(String)

    private static let newSessionType = "nook.shortcut.newSession"
    private static let askNookType = "nook.shortcut.askNook"
    private static let chatsType = "nook.shortcut.chats"
    private static let sessionType = "nook.shortcut.session"

    init?(_ item: UIApplicationShortcutItem) {
        switch item.type {
        case Self.newSessionType: self = .newSession
        case Self.askNookType: self = .askNook
        case Self.chatsType: self = .chats
        case Self.sessionType:
            guard let id = item.userInfo?["session"] as? String, !id.isEmpty else { return nil }
            self = .session(id)
        default: return nil
        }
    }

    /// The icon's quick actions: up to two sessions (the ones that need you first, then the newest), then the three
    /// starts. Titles and folders stay on the phone; nothing here leaves it.
    @MainActor
    static func update(sessions: [SessionDigest]) {
        let recent = sessions.sorted {
            (SessionListView.needsYou($0) ? 1 : 0, $0.updated) > (SessionListView.needsYou($1) ? 1 : 0, $1.updated)
        }
        var items: [UIApplicationShortcutItem] = recent.prefix(2).map { session in
            UIApplicationShortcutItem(type: sessionType, localizedTitle: session.title,
                                      localizedSubtitle: SessionListView.needsYou(session) ? String(localized: "Needs you") : session.folder,
                                      icon: UIApplicationShortcutIcon(systemImageName: SessionListView.needsYou(session) ? "hand.raised" : "text.bubble"),
                                      userInfo: ["session": session.id as NSString])
        }
        items += [
            UIApplicationShortcutItem(type: newSessionType, localizedTitle: String(localized: "New session"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "square.and.pencil"), userInfo: nil),
            UIApplicationShortcutItem(type: askNookType, localizedTitle: String(localized: "Ask Nook"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "sparkles"), userInfo: nil),
            UIApplicationShortcutItem(type: chatsType, localizedTitle: String(localized: "Answer a chat"), localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "bubble.left.and.bubble.right"), userInfo: nil),
        ]
        if UIApplication.shared.shortcutItems != items { UIApplication.shared.shortcutItems = items }
    }
}

/// Receives a quick action: at launch (the scene connects with it) and while the app runs.
final class ShortcutSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let item = connectionOptions.shortcutItem, let shortcut = AppShortcut(item) else { return }
        Task { @MainActor in CompanionClient.shared.pendingShortcut = shortcut }
    }

    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        guard let shortcut = AppShortcut(shortcutItem) else { return completionHandler(false) }
        Task { @MainActor in CompanionClient.shared.pendingShortcut = shortcut }
        completionHandler(true)
    }
}
