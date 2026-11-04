import Foundation

extension AppModel {
    /// Opens Settings on the page that holds `target` (Chat apps for a chat app, else Connections), on the Add sheet or
    /// one chat app's sheet when asked.
    func openConnections(_ target: ConnectionsRoute.Target? = nil) {
        ConnectionsRoute.shared.pending = target
        openSettings(section: SettingsSection.page(for: target))
    }
}
