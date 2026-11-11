import AppKit
import ObjectiveC

/// What the scenario process may not do, enforced at run time (docs/SCENARIOS.md): the app code runs here for real, so
/// anything that would show a window, take focus, open an app or run a real coding agent is refused instead, and written
/// to the guard log the report reads. ScenarioGuards.c does the same for the Keychain and `posix_spawn`.
enum ScenarioRuntimeGuards {
    private static var installed = false
    private static let lock = NSLock()
    private static var refusals: [String] = []

    /// What was refused since the last `drain()`.
    static func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = refusals
        refusals = []
        return taken
    }

    static func refuse(_ what: String) {
        lock.lock()
        refusals.append(what)
        lock.unlock()
        NSLog("NookScenarios guard: refused %@", what)
    }

    static func install(mainBundle: Bundle) {
        guard !installed else { return }
        installed = true
        _ = NSApplication.shared
        // Never in the Dock, never in front: a test process with a UI of its own would take the user's focus.
        NSApp.setActivationPolicy(.prohibited)

        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.scenario_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.scenario_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.scenario_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.scenario_order(_:relativeTo:)))
        swap(NSWindow.self, #selector(NSWindow.makeKey), #selector(NSWindow.scenario_makeKey))
        swap(NSApplication.self, #selector(NSApplication.activate(ignoringOtherApps:)), #selector(NSApplication.scenario_activate(ignoringOtherApps:)))
        swap(NSApplication.self, #selector(NSApplication.activate as (NSApplication) -> () -> Void), #selector(NSApplication.scenario_activateWithoutFlag))
        swap(NSApplication.self, #selector(NSApplication.setActivationPolicy(_:)), #selector(NSApplication.scenario_setActivationPolicy(_:)))
        swap(NSWorkspace.self, #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool), #selector(NSWorkspace.scenario_open(_:)))
        swap(NSWorkspace.self, #selector(NSWorkspace.open(_:configuration:completionHandler:)),
             #selector(NSWorkspace.scenario_open(_:configuration:completionHandler:)))
        swap(NSWorkspace.self, #selector(NSWorkspace.openApplication(at:configuration:completionHandler:)),
             #selector(NSWorkspace.scenario_openApplication(at:configuration:completionHandler:)))
        swap(NSAppleScript.self, #selector(NSAppleScript.executeAndReturnError(_:)), #selector(NSAppleScript.scenario_executeAndReturnError(_:)))
        // Process is a class cluster: guard the class that really launches.
        let taskClass: AnyClass = object_getClass(Process()) ?? Process.self
        swap(taskClass, #selector(Process.run as (Process) -> () throws -> Void), #selector(Process.scenario_run))
        swap(taskClass, #selector(Process.launch), #selector(Process.scenario_launch))
        // The app's icons and resources are looked up in the main bundle: this test bundle carries them.
        ScenarioMainBundle.bundle = mainBundle
        swapClass(Bundle.self, #selector(getter: Bundle.main), #selector(Bundle.scenario_main))
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else {
            NSLog("NookScenarios guard: cannot guard %@", NSStringFromSelector(original))
            return
        }
        // Added on the class itself first, so a method it only inherits is not swapped for its superclass too.
        if class_addMethod(cls, original, method_getImplementation(b), method_getTypeEncoding(b)) {
            class_replaceMethod(cls, replacement, method_getImplementation(a), method_getTypeEncoding(a))
        } else {
            method_exchangeImplementations(a, b)
        }
    }

    private static func swapClass(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let meta = object_getClass(cls), let a = class_getClassMethod(cls, original),
              let b = class_getClassMethod(cls, replacement) else { return }
        if class_addMethod(meta, original, method_getImplementation(b), method_getTypeEncoding(b)) {
            class_replaceMethod(meta, replacement, method_getImplementation(a), method_getTypeEncoding(a))
        } else {
            method_exchangeImplementations(a, b)
        }
    }

    /// Whether a program may run: the C guard decides, the same rule for Process and posix_spawn.
    static func allows(executable: String, arguments: [String]) -> Bool {
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        // The rule lives in ScenarioGuards.c; found by name, so the bundle needs no bridging header.
        // The bundle is loaded with local symbols, so it is asked by its own handle.
        let handle = dlopen(Bundle(for: ScenarioBundleMarker.self).executablePath, RTLD_NOLOAD | RTLD_LAZY)
        guard let symbol = dlsym(handle, "nook_scenario_spawn_allowed") else { return false }
        typealias Rule = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let rule = unsafeBitCast(symbol, to: Rule.self)
        return argv.withUnsafeBufferPointer { buffer in rule(executable, buffer.baseAddress) != 0 }
    }
}

/// A class of this bundle, to find the bundle by.
final class ScenarioBundleMarker {}

enum ScenarioMainBundle {
    static var bundle: Bundle?
}

extension Bundle {
    @objc class func scenario_main() -> Bundle {
        ScenarioMainBundle.bundle ?? scenario_main()
    }
}

extension NSWindow {
    @objc func scenario_makeKeyAndOrderFront(_ sender: Any?) {
        ScenarioRuntimeGuards.refuse("window to front: \(title.isEmpty ? String(describing: type(of: self)) : title)")
    }
    @objc func scenario_orderFront(_ sender: Any?) {
        ScenarioRuntimeGuards.refuse("window to front: \(title.isEmpty ? String(describing: type(of: self)) : title)")
    }
    @objc func scenario_orderFrontRegardless() {
        ScenarioRuntimeGuards.refuse("window to front regardless: \(String(describing: type(of: self)))")
    }
    @objc func scenario_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        // Taking a window off screen is always fine; putting one on screen is not.
        if place == .out { scenario_order(place, relativeTo: other); return }
        ScenarioRuntimeGuards.refuse("window ordered in: \(String(describing: type(of: self)))")
    }
    @objc func scenario_makeKey() {
        ScenarioRuntimeGuards.refuse("window made key: \(String(describing: type(of: self)))")
    }
}

extension NSApplication {
    @objc func scenario_activate(ignoringOtherApps flag: Bool) { ScenarioRuntimeGuards.refuse("NSApp.activate") }
    @objc func scenario_activateWithoutFlag() { ScenarioRuntimeGuards.refuse("NSApp.activate") }
    @objc func scenario_setActivationPolicy(_ policy: NSApplication.ActivationPolicy) -> Bool {
        guard policy == .prohibited else {
            ScenarioRuntimeGuards.refuse("activation policy \(policy.rawValue)")
            return false
        }
        return scenario_setActivationPolicy(policy)
    }
}

extension NSWorkspace {
    @objc func scenario_open(_ url: URL) -> Bool {
        ScenarioRuntimeGuards.refuse("open \(url.absoluteString.prefix(200))")
        return false
    }
    @objc func scenario_open(_ url: URL, configuration: NSWorkspace.OpenConfiguration,
                             completionHandler: ((NSRunningApplication?, Error?) -> Void)?) {
        ScenarioRuntimeGuards.refuse("open \(url.absoluteString.prefix(200))")
        completionHandler?(nil, CocoaError(.userCancelled))
    }
    @objc func scenario_openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration,
                                        completionHandler: ((NSRunningApplication?, Error?) -> Void)?) {
        ScenarioRuntimeGuards.refuse("open application \(url.path)")
        completionHandler?(nil, CocoaError(.userCancelled))
    }
}

extension NSAppleScript {
    @objc func scenario_executeAndReturnError(_ error: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> NSAppleEventDescriptor {
        // AppleScript would ask the user for Automation access to another app.
        ScenarioRuntimeGuards.refuse("AppleScript")
        return NSAppleEventDescriptor.null()
    }
}

extension Process {
    private var scenarioCommand: (String, [String]) {
        (executableURL?.path ?? launchPath ?? "", arguments ?? [])
    }

    @objc func scenario_run() throws {
        let (path, arguments) = scenarioCommand
        guard ScenarioRuntimeGuards.allows(executable: path, arguments: arguments) else {
            ScenarioRuntimeGuards.refuse("process \(path) \(arguments.prefix(4).joined(separator: " ").prefix(200))")
            throw CocoaError(.executableNotLoadable)
        }
        try scenario_run()
    }

    @objc func scenario_launch() {
        let (path, arguments) = scenarioCommand
        guard ScenarioRuntimeGuards.allows(executable: path, arguments: arguments) else {
            ScenarioRuntimeGuards.refuse("process \(path) \(arguments.prefix(4).joined(separator: " ").prefix(200))")
            return
        }
        scenario_launch()
    }
}
