import Foundation

extension AppModel {
    /// Opens Settings › Accounts & connections, on the Add sheet or one chat app's sheet when asked.
    func openConnections(_ target: ConnectionsRoute.Target? = nil) {
        ConnectionsRoute.shared.pending = target
        openSettings(section: .connections)
    }
}
