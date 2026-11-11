import Foundation
import AppKit
import Combine
import IOKit.ps
import os

/// Keeps the one answer to "how much may Nook do by himself right now" (`EnergyPlan`) for every background worker, so
/// none of them reads the battery, the thermal state or the load average on its own. The plan follows your choice in
/// Settings › Maintenance › Energy and the Mac's signals: it is read again every ten seconds and the moment macOS announces
/// a change (the charger, the battery's charge, Low Power Mode, the thermal state, the displays going to sleep or waking up,
/// the screen locking or unlocking).
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
    /// The last swap-in count and when it was read, for the rate in the next reading.
    private var lastSwapins: (count: UInt64, at: Date)?

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
        // The screen locking or unlocking: macOS posts these as distributed notifications.
        // The session dictionary may still say the old state when the notification arrives, so the notification's own
        // word counts for that read.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name), object: nil,
                                                                                 queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh(screenLocked: locked) }
            })
        }
        // The charger and the charge: IOKit tells right away, so neither the plug nor a battery that runs low waits for the
        // next tick.
        if let source = IOPSNotificationCreateRunLoopSource({ _ in
            Task { @MainActor in EnergyMonitor.shared.refresh() }
        }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        refresh()
    }

    /// Reads the Mac again and publishes the plan when it changed.
    /// `screenLocked` is what a lock or unlock notification just said, which wins over the session dictionary for this read.
    func refresh(screenLocked: Bool? = nil) {
        var now = SystemLoad.signals(wasLowBattery: signals.lowBattery, swapinsPerSecond: swapinRate())
        if let screenLocked { now.screenLocked = screenLocked }
        // Memory just ran short: let go of what can be rebuilt (a loaded model, caches) now, also when macOS itself still says
        // "normal" and so never sends its own warning (`MemoryPressure`).
        if now.memoryTight, !signals.memoryTight {
            Log.resources.notice("memory tight: optional work pauses, caches and models are let go")
            MemoryPressure.shared.purge(.warning)
        } else if !now.memoryTight, signals.memoryTight {
            Log.resources.notice("memory has room again")
        }
        if now != signals { signals = now }
        let next = EnergyPolicy.plan(for: now, mode: mode)
        if next != plan { plan = next }
    }

    /// Pages per second read back from swap since the last reading; nil on the first, or right after one (a burst of
    /// notifications) that is too close to say anything.
    private func swapinRate() -> Double? {
        guard let count = SystemLoad.swapins else { return nil }
        let now = Date()
        defer { if lastSwapins.map({ now.timeIntervalSince($0.at) >= 1 }) ?? true { lastSwapins = (count, now) } }
        guard let last = lastSwapins, count >= last.count else { return nil }
        let seconds = now.timeIntervalSince(last.at)
        guard seconds >= 1 else { return signals.memoryTight ? EnergySignals.swapinsPerSecondTight : 0 }
        return Double(count - last.count) / seconds
    }

    /// The status line: "Full speed", or what Nook holds back for and why.
    var statusText: String {
        guard let reason = plan.mainReason else { return tr("settings.energy.status.full") }
        let why = tr(reason.textKey)
        return plan.pace == .paused ? tr("settings.energy.status.paused", why) : tr("settings.energy.status.light", why)
    }
}
