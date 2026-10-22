import AppKit
import UserNotifications

/// Shows agent notices and permission requests as macOS notifications instead of notch cards (Settings › Notifications ›
/// Show notices as). A request whose whole command fits on the banner gets Allow and Deny there; anything you cannot
/// fully see on a banner (a dangerous or long command, a file edit's diff, an MCP tool) only gets Deny and Show, so what
/// is approved is always what was shown. A click on a notification opens it in the notch.
@MainActor
final class SystemNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = SystemNotifier()

    /// macOS does not let Nook show notifications (turned off in System Settings), so notices stay on the notch.
    @Published private(set) var blocked = false

    /// The longest command that may be allowed straight from a banner; longer ones are opened in the notch first.
    static let bannerLimit = 200

    private enum Category {
        static let approval = "nook.approval"
        static let approvalAlways = "nook.approval.always"
        static let review = "nook.approval.review"
        static let notice = "nook.notice"
    }

    private enum Action: String {
        case allow = "nook.allow"
        case always = "nook.always"
        case deny = "nook.deny"
        case show = "nook.show"
    }

    private struct Handlers {
        var decide: ((ApprovalDecision) -> Void)?
        var show: () -> Void
        /// Which post this is, so a request withdrawn while macOS is still answering is not posted after all.
        var token = UUID()
    }

    /// Notices (not approvals) kept clickable; older ones lose their action, so ignored banners do not pile up.
    static let noticeLimit = 20

    private let center = UNUserNotificationCenter.current()
    /// What each delivered notification does when you act on it, by its id (the token of the card it stands in for).
    private var handlers: [String: Handlers] = [:]
    /// The ids of notices with a handler, oldest first.
    private var notices: [String] = []

    /// Becomes the delegate. Called once at launch.
    func start() {
        center.delegate = self
        registerButtons()
    }

    /// The buttons, in the app's current language (registered again before each notification, so a language change shows).
    private func registerButtons() {
        let allow = UNNotificationAction(identifier: Action.allow.rawValue, title: tr("button.allow"))
        let always = UNNotificationAction(identifier: Action.always.rawValue, title: tr("button.always"))
        let deny = UNNotificationAction(identifier: Action.deny.rawValue, title: tr("button.deny"), options: [.destructive])
        let show = UNNotificationAction(identifier: Action.show.rawValue, title: tr("noticeDelivery.show"), options: [.foreground])
        center.setNotificationCategories([
            // A banner shows its first two buttons, so Deny is always one of them.
            UNNotificationCategory(identifier: Category.approval, actions: [allow, deny], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.approvalAlways, actions: [allow, deny, always], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.review, actions: [show, deny], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.notice, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
        ])
    }

    /// Asks macOS for permission to show notifications (only the first time does it ask you).
    func requestAccess() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Granted is not enough: alerts can be off in System Settings, and then no banner appears.
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let shows = Self.showsBanners(settings)
                Task { @MainActor in SystemNotifier.shared.blocked = !shows }
            }
        }
    }

    /// System Settings › Notifications, where Nook's notifications are turned on.
    static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Whether a request can be allowed from its banner: the whole command is on it and nothing about it needs a closer look.
    static func canAllowFromBanner(_ approval: AgentApproval) -> Bool {
        !approval.danger && approval.diff.isEmpty && McpToolName(approval.tool) == nil
            && approval.command.count <= bannerLimit && !approval.command.isEmpty
    }

    /// A permission request. `show` opens it in the notch; `fallback` runs when macOS does not let Nook notify, so the
    /// request is never lost.
    func approval(_ approval: AgentApproval, context: String, decide: @escaping (ApprovalDecision) -> Void,
                  show: @escaping () -> Void, fallback: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = approval.title
        content.subtitle = context
        if Self.canAllowFromBanner(approval) {
            content.body = approval.command
            content.categoryIdentifier = approval.canAlways ? Category.approvalAlways : Category.approval
        } else {
            let command = approval.command.count > Self.bannerLimit
                ? String(approval.command.prefix(Self.bannerLimit)) + "…" : approval.command
            content.body = [command, tr("noticeDelivery.review")].filter { !$0.isEmpty }.joined(separator: "\n")
            content.categoryIdentifier = Category.review
        }
        post(id: approval.cardToken, content: content, handlers: Handlers(decide: decide, show: show), fallback: fallback)
    }

    /// A notice (an agent is done, failed, asks something); a click runs `open`.
    func notice(id: String, title: String, subtitle: String = "", body: String = "", open: @escaping () -> Void,
                fallback: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = Category.notice
        post(id: id, content: content, handlers: Handlers(decide: nil, show: open), fallback: fallback)
    }

    /// The request was decided elsewhere or the agent moved on: its notification goes away, also one still being posted.
    func withdraw(_ id: String) {
        handlers[id] = nil
        notices.removeAll { $0 == id }
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    /// macOS shows Nook's banners: notifications allowed with alerts on (not only quietly in Notification Center, which
    /// is all provisional permission gives), so a request is seen and not left waiting unnoticed.
    nonisolated static func showsBanners(_ settings: UNNotificationSettings) -> Bool {
        settings.authorizationStatus == .authorized && settings.alertSetting == .enabled && settings.alertStyle != .none
    }

    private func post(id: String, content: UNMutableNotificationContent, handlers: Handlers, fallback: @escaping () -> Void) {
        // Nook plays its own (customizable) sounds, so the notification itself stays silent.
        content.sound = nil
        registerButtons()
        // Registered now, so a withdrawal while macOS answers below cancels this post.
        let token = handlers.token
        self.handlers[id] = handlers
        if handlers.decide == nil { keepNotice(id) }
        center.getNotificationSettings { settings in
            let allowed = Self.showsBanners(settings)
            Task { @MainActor in
                self.blocked = !allowed
                guard self.handlers[id]?.token == token else { return }
                guard allowed else {
                    self.forget(id)
                    fallback()
                    return
                }
                self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
                    Task { @MainActor in
                        let current = self.handlers[id]?.token == token
                        if error != nil {
                            guard current else { return }
                            self.forget(id)
                            fallback()
                        } else if !current, self.handlers[id] == nil {
                            // Withdrawn while it was being added.
                            self.center.removeDeliveredNotifications(withIdentifiers: [id])
                        }
                    }
                }
            }
        }
    }

    private func forget(_ id: String) {
        handlers[id] = nil
        notices.removeAll { $0 == id }
    }

    /// Keeps at most `noticeLimit` notices clickable: macOS tells nothing about a banner that was simply ignored.
    private func keepNotice(_ id: String) {
        notices.removeAll { $0 == id }
        notices.append(id)
        while notices.count > Self.noticeLimit {
            handlers[notices.removeFirst()] = nil
        }
    }

    private func respond(id: String, action: String) {
        notices.removeAll { $0 == id }
        guard let handler = handlers.removeValue(forKey: id) else { return }
        switch action {
        case Action.allow.rawValue: handler.decide?(.allow)
        case Action.always.rawValue: handler.decide?(.always)
        case Action.deny.rawValue: handler.decide?(.deny)
        case UNNotificationDismissActionIdentifier:
            // Closed without a choice: the request waits in the Agents tab.
            break
        default:
            handler.show()
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Nook is a menu bar app that counts as active, so banners are asked for explicitly.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            SystemNotifier.shared.respond(id: id, action: action)
            completionHandler()
        }
    }
}
