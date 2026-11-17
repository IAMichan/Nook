import Foundation

/// The notification settings for the phones, read and changed from a phone (docs/COMPANION.md, "Settings on the phone"):
/// the switches of Settings › Devices › Notifications (`CompanionStore.push`) and the quiet hours the Mac keeps with its
/// own notices (`NoticeRules.quietHours`). They hold for every paired phone, as on the Mac; a change needs the phone's
/// `operate` scope (`CompanionScopes`) and lands in the audit log.
extension CompanionServer {
    func notifySettings(_ request: CompanionRequest, deviceID: String, app: AppModel) -> CompanionResponse {
        CompanionResponse(id: request.id, ok: true, notify: currentNotify(deviceID: deviceID, app: app))
    }

    func notifySet(_ request: CompanionRequest, deviceID: String, app: AppModel) -> CompanionResponse {
        guard let wanted = request.notify, wanted.isValid else { return .failure(request.id, .badRequest) }
        let store = CompanionStore.shared
        let before = currentNotify(deviceID: deviceID, app: app)
        store.push = wanted.applied(to: store.push)
        var rules = app.settings.noticeRules
        if rules.quietHours != wanted.quietHours {
            rules.quietHours = wanted.quietHours
            app.settings.noticeRules = rules
        }
        let after = currentNotify(deviceID: deviceID, app: app)
        let phone = store.devices.first { $0.id == deviceID }?.name ?? deviceID
        audit("notify_settings", "\(phone) · " + after.changes(from: before))
        return CompanionResponse(id: request.id, ok: true, notify: after)
    }

    private func currentNotify(deviceID: String, app: AppModel) -> CompanionNotifySettings {
        let store = CompanionStore.shared
        var notify = CompanionNotifySettings(push: store.push, quiet: app.settings.noticeRules.quietHours)
        notify.registered = store.devices.first { $0.id == deviceID }?.pushToken != nil
        notify.canSend = CompanionNotifier.canSendAlerts
        return notify
    }
}
