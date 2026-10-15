import AppKit

// Custom entry point instead of `@main`: ensures the delegate remains retained (NSApplication holds it weakly).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
