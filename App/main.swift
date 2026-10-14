import AppKit

// Eigen startpunt in plaats van `@main`: de delegate blijft zo zeker in leven (NSApplication houdt hem maar zwak vast).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
