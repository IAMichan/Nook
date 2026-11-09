import AppKit
@preconcurrency import UserNotifications

/// What a macOS notification adds to a notice, besides the click that opens it: where it leads (kept in the
/// notification itself, so a click still works after Nook restarted or forgot it), which group it joins in Notification
/// Center, how much it may interrupt, and the buttons its banner offers.
struct NoticeBanner {
    /// What a click opens when the notice's own handler is gone (Nook restarted, or many notices came after it).
    var target: NoticeEntry.Target = .nowhere
    /// The group in Notification Center; from `target` when nil (one chat, one agent session).
    var thread: String?
    /// `.timeSensitive` for what waits on you, `.passive` for what can wait (a suggestion).
    var level: UNNotificationInterruptionLevel = .active
    /// Reply typed on the banner itself (a chat Nook writes in, a conversation with Nook).
    var reply: ((String) -> Void)?
    /// Mark as read (a chat).
    var read: (() -> Void)?
    /// A button that opens where the notice comes from ("Open Terminal").
    var app: (title: String, open: () -> Void)?
}

/// Shows notices as macOS notifications instead of on the notch, for every source set to "macOS notification" in
/// Settings › Notifications (`NoticeRules`), and an agent's permission requests when agents are. A request whose whole command fits on the banner gets Allow and Deny there; anything you cannot
/// fully see on a banner (a dangerous or long command, a file edit's diff, an MCP tool) only gets Deny and Show, so what
/// is approved is always what was shown. A click on a notification opens it in the notch.
///
/// Notifications are grouped per chat and per agent session, chats can be answered and marked read on the banner, and
/// a notification goes away once what it says is handled anywhere (read in Nook or in its app, decided in the notch).
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
        static let reply = "nook.notice.reply"
        static let chat = "nook.notice.chat"
        static let chatReply = "nook.notice.chat.reply"
        /// Followed by the button's title: one category per app name ("Open Terminal", "Open Ghostty").
        static let appPrefix = "nook.notice.app."
        static let approvals: Set<String> = [approval, approvalAlways, review]
    }

    private enum Action: String {
        case allow = "nook.allow"
        case always = "nook.always"
        case deny = "nook.deny"
        case show = "nook.show"
        case reply = "nook.reply"
        case read = "nook.read"
        case app = "nook.app"
    }

    /// What was done on a notification whose handler is gone: `orphan` answers it from the notification's target.
    enum Response {
        case open
        case reply(String)
        case read
    }

    /// Answers a notification Nook no longer holds a handler for (set by `AppModel` at launch).
    var orphan: ((NoticeEntry.Target, Response) -> Void)?

    private struct Handlers {
        var decide: ((ApprovalDecision) -> Void)?
        var show: () -> Void
        var banner = NoticeBanner()
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
    /// The notifications Nook posted since launch that are still up, by id: what is handled elsewhere is withdrawn
    /// from these.
    private(set) var live: Set<String> = []
    /// The titles of the "Open …" buttons posted so far, each its own category.
    private var appButtons: Set<String> = []

    /// Becomes the delegate. Called once at launch.
    func start() {
        center.delegate = self
        registerButtons()
        removeStaleRequests()
    }

    /// Permission requests still in Notification Center from before Nook restarted: their agent no longer waits on
    /// Nook for them, so Allow there would do nothing. They go; the notch asks again for what is still open.
    private func removeStaleRequests() {
        Task {
            let delivered = await center.deliveredNotifications()
            let stale = delivered.filter {
                Category.approvals.contains($0.request.content.categoryIdentifier) && handlers[$0.request.identifier] == nil
            }.map(\.request.identifier)
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    /// The buttons, in the app's current language (registered again before each notification, so a language change shows).
    private func registerButtons() {
        let allow = UNNotificationAction(identifier: Action.allow.rawValue, title: tr("button.allow"))
        let always = UNNotificationAction(identifier: Action.always.rawValue, title: tr("button.always"))
        let deny = UNNotificationAction(identifier: Action.deny.rawValue, title: tr("button.deny"), options: [.destructive])
        let show = UNNotificationAction(identifier: Action.show.rawValue, title: tr("noticeDelivery.show"), options: [.foreground])
        let reply = UNTextInputNotificationAction(identifier: Action.reply.rawValue, title: tr("noticeDelivery.reply"),
                                                  textInputButtonTitle: tr("noticeDelivery.send"),
                                                  textInputPlaceholder: tr("noticeDelivery.replyPrompt"))
        let read = UNNotificationAction(identifier: Action.read.rawValue, title: tr("noticeDelivery.markRead"))
        let apps = appButtons.map {
            UNNotificationCategory(identifier: Category.appPrefix + $0,
                                   actions: [UNNotificationAction(identifier: Action.app.rawValue, title: $0)],
                                   intentIdentifiers: [], options: [.customDismissAction])
        }
        center.setNotificationCategories(Set(apps + [
            // A banner shows its first two buttons, so Deny is always one of them.
            UNNotificationCategory(identifier: Category.approval, actions: [allow, deny], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.approvalAlways, actions: [allow, deny, always], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.review, actions: [show, deny], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.notice, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.reply, actions: [reply], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.chat, actions: [read], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: Category.chatReply, actions: [reply, read], intentIdentifiers: [],
                                   options: [.customDismissAction]),
        ]))
    }

    /// The buttons a notice's banner gets.
    private func category(_ banner: NoticeBanner) -> String {
        switch (banner.reply != nil, banner.read != nil) {
        case (true, true): return Category.chatReply
        case (true, false): return Category.reply
        case (false, true): return Category.chat
        case (false, false):
            guard let app = banner.app else { return Category.notice }
            appButtons.insert(app.title)
            return Category.appPrefix + app.title
        }
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
    func approval(_ approval: AgentApproval, context: String, target: NoticeEntry.Target,
                  decide: @escaping (ApprovalDecision) -> Void, show: @escaping () -> Void, fallback: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = approval.title
        content.subtitle = context
        // It waits on you: it may come through a Focus (where macOS lets Nook), and leads its group.
        let banner = NoticeBanner(target: target, level: .timeSensitive)
        apply(banner, to: content)
        if Self.canAllowFromBanner(approval) {
            content.body = approval.command
            content.categoryIdentifier = approval.canAlways ? Category.approvalAlways : Category.approval
        } else {
            let command = approval.command.count > Self.bannerLimit
                ? String(approval.command.prefix(Self.bannerLimit)) + "…" : approval.command
            content.body = [command, tr("noticeDelivery.review")].filter { !$0.isEmpty }.joined(separator: "\n")
            content.categoryIdentifier = Category.review
        }
        post(id: approval.cardToken, content: content, handlers: Handlers(decide: decide, show: show, banner: banner),
             fallback: fallback)
    }

    /// A notice (an agent is done, failed, asks something; a message came in); a click runs `open`, the banner's buttons
    /// what `banner` gives. A newer notice with the same `id` replaces the one before.
    func notice(id: String, title: String, subtitle: String = "", body: String = "", banner: NoticeBanner = NoticeBanner(),
                open: @escaping () -> Void, fallback: @escaping () -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        apply(banner, to: content)
        content.categoryIdentifier = category(banner)
        post(id: id, content: content, handlers: Handlers(decide: nil, show: open, banner: banner), fallback: fallback)
    }

    /// The group, the interruption level and the stored target of a notification.
    private func apply(_ banner: NoticeBanner, to content: UNMutableNotificationContent) {
        content.threadIdentifier = banner.thread ?? banner.target.thread
        content.interruptionLevel = banner.level
        content.relevanceScore = banner.level == .timeSensitive ? 1 : banner.level == .passive ? 0 : 0.5
        content.userInfo = banner.target.stored
    }

    /// The request was decided elsewhere or the agent moved on: its notification goes away, also one still being posted.
    func withdraw(_ id: String) {
        live.remove(id)
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
        live.insert(id)
        if handlers.decide == nil { keepNotice(id) }
        Task {
            let allowed = Self.showsBanners(await center.notificationSettings())
            blocked = !allowed
            guard self.handlers[id]?.token == token else { return }
            guard allowed else {
                forget(id)
                fallback()
                return
            }
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
                if self.handlers[id]?.token != token, self.handlers[id] == nil {
                    // Withdrawn while it was being added.
                    center.removeDeliveredNotifications(withIdentifiers: [id])
                }
            } catch {
                guard self.handlers[id]?.token == token else { return }
                forget(id)
                fallback()
            }
        }
    }

    private func forget(_ id: String) {
        live.remove(id)
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

    private func respond(id: String, action: String, text: String?, target: NoticeEntry.Target) {
        notices.removeAll { $0 == id }
        live.remove(id)
        // Closed without a choice: a request waits in the Agents tab, a message in Chats.
        guard action != UNNotificationDismissActionIdentifier else {
            handlers[id] = nil
            return
        }
        guard let handler = handlers.removeValue(forKey: id) else {
            // Nook restarted, or forgot it after many newer notices: the notification itself says where it leads.
            switch action {
            case Action.reply.rawValue: if let text { orphan?(target, .reply(text)) }
            case Action.read.rawValue: orphan?(target, .read)
            // An old permission request cannot be answered any more: its session shows what it waits on.
            default: orphan?(target, .open)
            }
            return
        }
        switch action {
        case Action.allow.rawValue: handler.decide?(.allow)
        case Action.always.rawValue: handler.decide?(.always)
        case Action.deny.rawValue: handler.decide?(.deny)
        case Action.reply.rawValue: if let text { handler.banner.reply?(text) }
        case Action.read.rawValue: handler.banner.read?()
        case Action.app.rawValue: handler.banner.app?.open()
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
        let text = (response as? UNTextInputNotificationResponse)?.userText
        let target = NoticeEntry.Target(stored: response.notification.request.content.userInfo)
        Task { @MainActor in
            SystemNotifier.shared.respond(id: id, action: action, text: text, target: target)
            completionHandler()
        }
    }
}
