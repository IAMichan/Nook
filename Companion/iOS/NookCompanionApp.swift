import SwiftUI

@main
struct NookCompanionApp: App {
    @StateObject private var client = CompanionClient()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(client)
                // The Mac's QR code opens the app with the pairing link when scanned with the Camera app.
                .onOpenURL { url in client.pair(link: url.absoluteString) }
        }
    }
}
