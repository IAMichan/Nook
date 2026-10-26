import AppKit

// Custom entry point instead of `@main`: ensures the delegate remains retained (NSApplication holds it weakly).
MainActor.assumeIsolated {
    // First, before anything opens the database: an update on trial that crashed is rolled back here (UpdateTrial).
    UpdateTrialRunner.atLaunch()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    withExtendedLifetime(delegate) {}
}
