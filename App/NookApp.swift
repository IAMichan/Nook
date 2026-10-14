import SwiftUI

@main
struct NookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Nook heeft geen gewoon venster; alles gebeurt in de notch en het menubalk-icoon.
        // Instellingen openen in een eigen venster (AppModel.openSettings).
        Settings { EmptyView() }
    }
}
