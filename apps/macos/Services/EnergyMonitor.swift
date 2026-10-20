import Foundation
import AppKit
import Combine
import IOKit.ps

/// Keeps the one answer to "how much may Nook do by himself right now" (`EnergyPlan`) for every background worker, so
/// none of them reads the battery, the thermal state or the load average on its own. The plan follows your choice in
/// Settings › General › Energy and the Mac's signals: it is read again every ten seconds and the moment macOS announces
/// a change (the charger, Low Power Mode, the thermal state, the displays going to sleep or waking up).
///
/// Only a changed plan is published: the status line in Settings redraws for it, nothing else does for a tick that
/// found the same.
@MainActor
final class EnergyMonitor: ObservableObject {
    static let shared = EnergyMonitor()

    @Published private(set) var plan = EnergyPlan.fullSpeed
    @Published private(set) var signals = EnergySignals()

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var bag = Set<AnyCancellable>()
    /// Your choice in Settings, mirrored here so a tick does not read the settings.
    private var mode: EnergyMode = .automatic

    private init() {}

    /// Starts following the Mac and your choice. Safe to call more than once.
    func start(settings: AppSettings) {
        guard timer == nil else { return }
        mode = settings.energyMode
        settings.$energyMode
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.mode = mode
                self?.refresh()
            }
            .store(in: &bag)

        timer = Timer.scheduledCoalesced(withTimeInterval: 10) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let names: [(NotificationCenter, Notification.Name)] = [
            (NotificationCenter.default, .NSProcessInfoPowerStateDidChange),
            (NotificationCenter.default, ProcessInfo.thermalStateDidChangeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification)
        ]
        for (center, name) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        // The charger: IOKit tells right away, so the plan does not wait for the next tick.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in EnergyMonitor.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        refresh()
    }

    /// Reads the Mac again and publishes the plan when it changed.
    func refresh() {
        let now = SystemLoad.signals()
        if now != signals { signals = now }
        let next = EnergyPolicy.plan(for: now, mode: mode)
        if next != plan { plan = next }
    }

    /// The status line: "Full speed", or what Nook holds back for and why.
    var statusText: String {
        guard let reason = plan.mainReason else { return tr("settings.energy.status.full") }
        let why = tr(reason.textKey)
        return plan.pace == .paused ? tr("settings.energy.status.paused", why) : tr("settings.energy.status.light", why)
    }
}
