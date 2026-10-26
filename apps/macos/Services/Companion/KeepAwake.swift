import AppKit
import Combine
import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac awake while the iPhone companion may need it (`KeepAwakePolicy`): while agents work or wait on you,
/// while a phone is connected live, or always, as chosen in Settings › Devices › Away from home. On the power adapter it
/// holds off all sleep, so a MacBook stays reachable with its lid closed; on battery only idle sleep, and only for work
/// or a phone. The screen may always turn off. What it holds shows in Activity Monitor and `pmset -g assertions` as
/// "Nook: …".
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published var mode: KeepAwakePolicy.Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey); update() }
    }
    @Published private(set) var decision = KeepAwakePolicy.Decision.none

    private static let modeKey = "companion.keepAwake"
    private weak var app: AppModel?
    private var assertions: [IOPMAssertionID] = []
    private var lastBusy: Date?
    private var watch: AnyCancellable?
    private var timer: Timer?

    init() {
        mode = UserDefaults.standard.string(forKey: Self.modeKey).flatMap(KeepAwakePolicy.Mode.init(rawValue:)) ?? .whileWorking
    }

    func attach(app: AppModel) {
        self.app = app
        // A session that starts or stops working; at most one look every two seconds.
        watch = app.workspace.objectWillChange.merge(with: app.hub.objectWillChange)
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.update() } }
        // The power adapter, the battery, the end of the grace period, agents in a terminal: looked at every 30 seconds.
        timer = Timer.scheduledCoalesced(withTimeInterval: 30) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    /// Takes in what changed (a session, a phone connecting, the companion switched off) and holds what the policy says.
    func update(now: Date = Date()) {
        guard let app, CompanionStore.shared.enabled else { hold(.none); return }
        let working = CompanionServer.shared.digests(app).contains {
            KeepAwakePolicy.isBusy(attention: $0.attention, waiting: !$0.items.isEmpty)
        }
        if working { lastBusy = now }
        let busy = working || lastBusy.map { now.timeIntervalSince($0) < KeepAwakePolicy.grace } == true
        let power = PowerSource.current()
        let next = KeepAwakePolicy.decide(mode: mode, busy: busy, phoneConnected: CompanionServer.shared.hasLivePhone,
                                          onPower: power.onPower, battery: power.battery)
        if next != decision { decision = next }
        hold(next.hold)
    }

    private var held: KeepAwakePolicy.Hold = .none

    private func hold(_ hold: KeepAwakePolicy.Hold) {
        guard hold != held else { return }
        for id in assertions { IOPMAssertionRelease(id) }
        assertions = []
        held = hold
        if hold == .none {
            if decision != .none { decision = .none }
            return
        }
        var kinds = [kIOPMAssertionTypePreventUserIdleSystemSleep]
        // Holds off sleep altogether (lid closed included); macOS honors it on the power adapter only.
        if hold == .system { kinds.append(kIOPMAssertionTypePreventSystemSleep) }
        for kind in kinds {
            var id = IOPMAssertionID(0)
            let name = "Nook: keeps this Mac reachable for your iPhone" as CFString
            if IOPMAssertionCreateWithName(kind as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id) == kIOReturnSuccess {
                assertions.append(id)
            }
        }
    }
}

/// Whether the Mac runs on the power adapter, and its battery's charge in percent (nil without a battery).
enum PowerSource {
    static func current() -> (onPower: Bool, battery: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (true, nil) }
        let providing = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()).map { $0 as String }
        var battery: Int?
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                battery = current * 100 / max
            }
        }
        // A Mac without a battery (a Mac mini, an iMac) reports no source at all: it is on power.
        return (providing.map { $0 != kIOPSBatteryPowerValue } ?? true, battery)
    }
}
