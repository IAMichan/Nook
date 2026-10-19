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
                // The Mac's QR code opens the app with the pairing link when scanned with the Camera app.
                .onOpenURL { url in client.pair(link: url.absoluteString) }
        }
    }
}

/// Receives the push token and what happens with notifications: a tap opens the session, the buttons answer an approval.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Notifications.registerCategories()
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

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
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
