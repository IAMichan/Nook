import AppKit
import ApplicationServices
import AVFoundation
import Contacts
import EventKit
import ScreenCaptureKit
import Speech

/// Whether Nook may read the screen without the user asking (the screen context timer, think-along, the brain's
/// read_screen). `CGPreflightScreenCaptureAccess` can say yes while ScreenCaptureKit still says no: after a rebuild macOS
/// no longer matches to the Screen Recording switch (an ad-hoc signature changes with every build), the switch still
/// shows Nook as on, and every capture shows the system prompt again. The first such refusal stops automatic reads until
/// Nook restarts, which macOS asks for after changing the switch anyway.
@MainActor
enum ScreenAccess {
    /// Only written on the main actor; a stale read from elsewhere only delays the stop by one check.
    nonisolated(unsafe) private(set) static var refused = false

    /// True when an automatic read may call ScreenCaptureKit. Nonisolated: `SystemPermission.isGranted` asks from any thread.
    nonisolated static var isUsable: Bool { !refused && CGPreflightScreenCaptureAccess() }

    /// Called with the error of a failed capture: a refusal turns automatic reads off for this launch.
    static func note(_ error: Error) {
        let error = error as NSError
        if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue { refused = true }
    }
}

/// Every macOS privacy permission Nook asks for, in one place: whether it is granted, how to ask for it, and where it lives in
/// System Settings › Privacy & Security.
enum SystemPermission: String, CaseIterable, Identifiable {
    case screen, accessibility, inputMonitoring, calendar, reminders, contacts, microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screen: return tr("settings.privacy.screenReading")
        case .accessibility: return tr("settings.privacy.accessibility")
        case .inputMonitoring: return tr("settings.privacy.inputMonitoring")
        case .calendar: return tr("settings.privacy.calendar")
        case .reminders: return tr("settings.privacy.reminders")
        case .contacts: return tr("settings.privacy.contacts")
        case .microphone: return tr("settings.privacy.micSpeech")
        }
    }

    var detail: String {
        switch self {
        case .screen: return tr("settings.privacy.screenReadingDetail")
        case .accessibility: return tr("settings.privacy.accessibilityDetail")
        case .inputMonitoring: return tr("settings.privacy.inputMonitoringDetail")
        case .calendar: return tr("settings.privacy.calendarDetail")
        case .reminders: return tr("settings.privacy.remindersDetail")
        case .contacts: return tr("settings.privacy.contactsDetail")
        case .microphone: return tr("settings.privacy.micSpeechDetail")
        }
    }

    /// Asks macOS without showing anything.
    var isGranted: Bool {
        switch self {
        case .screen: return ScreenAccess.isUsable
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .calendar: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .contacts: return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized && SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    /// True once macOS asked the user and the answer was no: asking again shows nothing, only System Settings can change it.
    private var wasDenied: Bool {
        switch self {
        case .calendar: return [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .event))
        case .reminders: return [.denied, .restricted, .writeOnly].contains(EKEventStore.authorizationStatus(for: .reminder))
        case .contacts: return [.denied, .restricted].contains(CNContactStore.authorizationStatus(for: .contacts))
        case .microphone:
            return [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
                || [.denied, .restricted].contains(SFSpeechRecognizer.authorizationStatus())
        case .screen, .accessibility, .inputMonitoring: return false
        }
    }

    /// The pane in System Settings › Privacy & Security.
    private var settingsAnchor: String {
        switch self {
        case .screen: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .calendar: return "Privacy_Calendars"
        case .reminders: return "Privacy_Reminders"
        case .contacts: return "Privacy_Contacts"
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "Privacy_SpeechRecognition" : "Privacy_Microphone"
        }
    }

    @MainActor
    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)") {
            PermissionMonitor.shared.openedSettings = Date()
            NSWorkspace.shared.open(url)
        }
    }

    /// Asks macOS. Asking first is what puts Nook in the list in System Settings; for a permission macOS only grants there
    /// (screen, Accessibility, Input Monitoring) or one the user already turned down, that pane opens too.
    @MainActor
    func request(app: AppModel) async {
        guard !isGranted else { return }
        if wasDenied { openSettings(); return }
        switch self {
        case .screen:
            // Refused while the switch is on: asking again shows nothing useful, the switch needs turning off and on.
            if ScreenAccess.refused || !CGRequestScreenCaptureAccess() { openSettings() }
        case .accessibility:
            if !AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) { openSettings() }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings() }
        case .calendar:
            await app.calendar.requestEvents()
            app.connectors.refreshAll()
        case .reminders:
            await app.calendar.requestReminders()
            app.connectors.refreshAll()
        case .contacts:
            _ = try? await CNContactStore().requestAccess(for: .contacts)
        case .microphone:
            _ = await app.voice.requestPermissions()
        }
    }
}

/// Keeps the answer to "is this permission granted?" current. macOS sends no notice when the user flips a switch in System
/// Settings, so Nook checks again whenever it comes to the front, and every second while a screen with permissions is open.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var granted: [SystemPermission: Bool]
    /// When Nook last opened System Settings for a permission: Nook then stays behind it instead of coming back to the front.
    var openedSettings: Date?

    private var watchers = 0
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    private init() {
        granted = Self.check()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func isGranted(_ permission: SystemPermission) -> Bool { granted[permission] ?? false }

    /// Checks every permission again. When Accessibility or Input Monitoring changed, the features that need them start
    /// (or stop) right away.
    func refresh() {
        let now = Self.check()
        let trusted = now[.accessibility] ?? false
        let keysChanged = [SystemPermission.accessibility, .inputMonitoring].contains { now[$0] != granted[$0] }
        if now != granted { granted = now }
        // Also when their own copy of the answer went stale, whatever this monitor saw before.
        if keysChanged || AutocompleteController.shared.trusted != trusted { AutocompleteController.shared.refresh() }
        if keysChanged || FlowDictation.shared.trusted != trusted { FlowDictation.shared.refresh() }
    }

    /// Asks for a permission and records the answer.
    func request(_ permission: SystemPermission, app: AppModel) async {
        await permission.request(app: app)
        refresh()
    }

    /// A view that shows permissions calls this on appear and `unwatch()` on disappear: while one is open, Nook checks every second.
    func watch() {
        watchers += 1
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    private static func check() -> [SystemPermission: Bool] {
        Dictionary(uniqueKeysWithValues: SystemPermission.allCases.map { ($0, $0.isGranted) })
    }
}
