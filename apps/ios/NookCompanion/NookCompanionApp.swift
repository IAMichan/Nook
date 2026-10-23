import SwiftUI
import UserNotifications

@main
struct NookCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var client = CompanionClient.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                // A tap on a Live Activity opens its session; the Mac's QR code, scanned with the Camera app, opens the
                // app with the pairing link; a prompt link (nook://prompt?text=…) opens a new session with its text
                // filled in, never sent.
                .onOpenURL { url in
                    if let session = ActivityLink.session(from: url) {
                        client.openSession = session
                    } else if let prompt = PromptLink.parse(url: url) {
                        client.pendingPrompt = prompt
                    } else {
                        client.pair(link: url.absoluteString)
                    }
                }
        }
    }
}

/// Receives the push token and what happens with notifications: a tap opens the session, the buttons answer an approval.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notifications.registerCategories()
        Task { @MainActor in LiveActivities.shared.start() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await CompanionClient.shared.registerPush(token: deviceToken) }
    }

    /// A push with content-available: look at the Mac again, so the list is current when you open the app.
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await CompanionClient.shared.refresh()
        return .newData
    }

    /// No banner or sound for the session you are looking at: its screen already shows what changed.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let nook = notification.request.content.userInfo["nook"] as? [String: Any]
        let session = nook?["session"] as? String
        let visible = await MainActor.run { CompanionClient.shared.visibleSession }
        if let session, session == visible { return [.badge] }
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let nook = response.notification.request.content.userInfo["nook"] as? [String: Any]
        let session = nook?["session"] as? String
        let item = nook?["item"] as? String
        switch response.actionIdentifier {
        case PushCategory.actionAllow, PushCategory.actionDeny:
            guard let session, let item else { return }
            await CompanionClient.shared.decide(sessionID: session, itemID: item, allow: response.actionIdentifier == PushCategory.actionAllow)
        default:
            if let session { await MainActor.run { CompanionClient.shared.openSession = session } }
        }
    }
}
