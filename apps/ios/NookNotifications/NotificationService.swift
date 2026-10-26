import UserNotifications

/// Opens notifications that came through Nook's relay (docs/COMPANION.md, "Push through Nook's relay"). Apple delivers
/// them with a generic "Nook needs you" and the real content sealed with the pairing's push key under "nook-sealed";
/// this extension opens it with the key the app keeps in the shared Keychain (`PushKeyStore`) and writes the title,
/// text, buttons, thread and badge. When it cannot (no key, a key from a removed pairing, a damaged blob), the
/// notification stays generic. Notifications sent with the Mac's own APNs key carry no blob and pass unchanged.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        handler = contentHandler
        fallback = content
        guard let envelope = RelayPush.envelope(fromUserInfo: request.content.userInfo["nook-sealed"]) else {
            return contentHandler(content)
        }
        content.userInfo["nook-sealed"] = nil
        guard let device = CompanionSeal.claimedDevice(envelope), let key = PushKeyStore.key(forDevice: device),
              let opened = try? RelayPush.open(envelope, pushKey: key) else {
            content.title = "Nook"
            content.body = String(localized: "Nook needs you")
            return contentHandler(content)
        }
        content.title = opened.title
        content.body = opened.body
        content.categoryIdentifier = opened.category
        content.threadIdentifier = opened.thread
        content.badge = NSNumber(value: opened.badge)
        for (key, value) in opened.userInfo { content.userInfo[key] = value }
        contentHandler(content)
    }

    /// Out of time: deliver what Apple sent, generic.
    override func serviceExtensionTimeWillExpire() {
        if let handler, let fallback { handler(fallback) }
    }
}
