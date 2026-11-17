import SwiftUI

// Settings › Notifications and "What this iPhone may do" (docs/COMPANION.md, "Settings on the phone"): the Mac's
// notification switches for its phones (Settings › Devices › Notifications there) and its quiet hours, read and changed
// from here (`CompanionFeature.notifySettings`); and the scopes the Mac gave this iPhone, to read only.

/// The Mac's notification settings as a group of rows. A change goes to the Mac at once; it holds for every phone paired
/// with it, as on the Mac. Without the `operate` scope the rows show but cannot change.
struct NotifySettingsGroup: View {
    @EnvironmentObject private var client: CompanionClient

    private var settings: CompanionNotifySettings? { client.notify }
    private var canChange: Bool { client.allows(.operate) && client.phase == .connected }

    var body: some View {
        SettingsGroup(title: String(localized: "Notifications")) {
            if let settings {
                SettingsToggleRow(symbol: settings.enabled ? "bell.badge" : "bell.slash", title: String(localized: "Notifications"),
                                  detail: detail(settings), isOn: bind(\.enabled))
                if settings.enabled {
                    ForEach(PushEvent.Kind.allCases, id: \.self) { kind in
                        SettingsToggleRow(symbol: Self.symbol(kind), title: Self.title(kind), isOn: kindBinding(kind))
                    }
                    SettingsToggleRow(symbol: "figure.walk", title: String(localized: "Only when you are away from the Mac"),
                                      detail: String(localized: "At your desk the Mac's own cards are enough."), isOn: bind(\.onlyWhenAway))
                    SettingsToggleRow(symbol: "text.quote", title: String(localized: "Show session titles"),
                                      detail: String(localized: "Off by default: Apple relays the text."), isOn: bind(\.includeTitle))
                }
                SettingsToggleRow(symbol: "moon", title: String(localized: "Quiet hours"),
                                  detail: String(localized: "The same hours as the Mac's own notices."), isOn: quietBinding)
                if let from = settings.quietFrom, let to = settings.quietTo {
                    SettingsRow(symbol: "clock", title: String(localized: "From")) { hourMenu(from) { setHour(start: true, $0) } }
                    SettingsRow(symbol: "clock.badge.checkmark", title: String(localized: "Until")) { hourMenu(to) { setHour(start: false, $0) } }
                    SettingsToggleRow(symbol: "hand.raised", title: String(localized: "Let approvals and questions through"),
                                      isOn: bind(\.quietAllowsUrgent))
                }
                if !client.allows(.operate) {
                    SettingsRow(symbol: "lock", title: String(localized: "Only your Mac can change these for this iPhone"),
                                detail: String(localized: "Starting and managing sessions is off for it in Settings › Devices."))
                }
            } else {
                SettingsRow(symbol: "bell", title: String(localized: "Loading…"))
            }
        }
        .disabled(!canChange)
        .task { await client.loadNotify() }
    }

    private func detail(_ settings: CompanionNotifySettings) -> String {
        if settings.canSend == false { return String(localized: "Not set up on your Mac yet (Settings › iPhone companion).") }
        if settings.registered == false { return String(localized: "Allow notifications for Nook in the iPhone's Settings.") }
        return String(localized: "From your Mac, for every phone paired with it.")
    }

    // MARK: Changes

    private func change<Value>(_ apply: @escaping (inout CompanionNotifySettings, Value) -> Void) -> (Value) -> Void {
        { value in
            guard var next = client.notify, canChange else { return }
            apply(&next, value)
            next.registered = nil
            next.canSend = nil
            guard next.isValid else { return }
            Haptics.tap()
            let kept = client.notify
            client.notify = next.with(kept)
            Task {
                let ok = await client.setNotify(next)
                if !ok { client.notify = kept }
            }
        }
    }

    private func bind(_ path: WritableKeyPath<CompanionNotifySettings, Bool>) -> Binding<Bool> {
        Binding(get: { client.notify?[keyPath: path] ?? false },
                set: { value in change { (settings: inout CompanionNotifySettings, value: Bool) in settings[keyPath: path] = value }(value) })
    }

    private func kindBinding(_ kind: PushEvent.Kind) -> Binding<Bool> {
        Binding(get: { client.notify?.kinds.contains(kind.rawValue) ?? false },
                set: { on in
                    change { (settings: inout CompanionNotifySettings, on: Bool) in
                        var kinds = Set(settings.kinds)
                        if on { kinds.insert(kind.rawValue) } else { kinds.remove(kind.rawValue) }
                        settings.kinds = PushEvent.Kind.allCases.map(\.rawValue).filter(kinds.contains)
                    }(on)
                })
    }

    private func setHour(start: Bool, _ hour: Int) {
        change { (settings: inout CompanionNotifySettings, hour: Int) in
            if start { settings.quietFrom = hour } else { settings.quietTo = hour }
        }(hour)
    }

    private var quietBinding: Binding<Bool> {
        Binding(get: { client.notify?.quietHours != nil },
                set: { on in
                    change { (settings: inout CompanionNotifySettings, on: Bool) in
                        let hours = on ? QuietHours.evening : nil
                        settings.quietFrom = hours?.from
                        settings.quietTo = hours?.to
                    }(on)
                })
    }

    private func hourMenu(_ hour: Int, pick: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<24, id: \.self) { value in
                Button(Self.hourText(value)) { pick(value) }
            }
        } label: {
            Text(Self.hourText(hour)).font(Theme.TextStyle.label).monospacedDigit().foregroundStyle(Theme.paper)
                .frame(minWidth: 64, minHeight: 44, alignment: .trailing)
        }
    }

    static func hourText(_ hour: Int) -> String {
        var parts = DateComponents()
        parts.hour = hour
        parts.minute = 0
        let date = Calendar.current.date(from: parts) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func title(_ kind: PushEvent.Kind) -> String {
        switch kind {
        case .approval: return String(localized: "Approvals")
        case .question: return String(localized: "Questions")
        case .finished: return String(localized: "Finished sessions")
        case .failed: return String(localized: "Failed sessions")
        case .limited: return String(localized: "Usage limit reached")
        }
    }

    static func symbol(_ kind: PushEvent.Kind) -> String {
        switch kind {
        case .approval: return "hand.raised.fill"
        case .question: return "questionmark.bubble"
        case .finished: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .limited: return "hourglass"
        }
    }
}

private extension CompanionNotifySettings {
    /// The change, keeping what the Mac said of this phone (registered, can send) until it answers.
    func with(_ kept: CompanionNotifySettings?) -> CompanionNotifySettings {
        var next = self
        next.registered = kept?.registered
        next.canSend = kept?.canSend
        return next
    }
}

/// What the Mac lets this iPhone do (its scopes, chosen on the Mac when it paired and in Settings › Devices), to read.
struct PhoneScopesGroup: View {
    @EnvironmentObject private var client: CompanionClient

    var body: some View {
        SettingsGroup(title: String(localized: "What this iPhone may do")) {
            ForEach(CompanionScope.allCases, id: \.self) { scope in
                let allowed = client.allows(scope)
                SettingsRow(symbol: allowed ? "checkmark.circle.fill" : "minus.circle", title: Self.title(scope),
                            tint: allowed ? Theme.mint : Theme.textTertiary)
            }
            SettingsRow(symbol: "laptopcomputer", title: String(localized: "Change this on your Mac"),
                        detail: String(localized: "Settings › Devices, under this iPhone."))
        }
    }

    static func title(_ scope: CompanionScope) -> String {
        switch scope {
        case .read: return String(localized: "See sessions, pull requests and usage")
        case .approve: return String(localized: "Allow, deny and answer")
        case .operate: return String(localized: "Start, message, review and merge")
        case .chats: return String(localized: "Read and answer chats")
        case .music: return String(localized: "Control music")
        case .nookChat: return String(localized: "Chat with Nook")
        }
    }
}
