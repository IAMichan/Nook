import AppKit
import Combine

/// The call you started from a chat, followed while it lasts: whether its app holds the microphone yet
/// (`ChatCallTracker`) and which microphone, sound output and camera it uses. It reads every two seconds while a call
/// shows, off the main thread, and not at all otherwise; `ChatCallBadge` shows it.
@MainActor
final class ChatCallCenter: ObservableObject {
    static let shared = ChatCallCenter()

    struct Call: Equatable {
        let id = UUID()
        /// The chat, for its face and to open it again.
        let entry: ChatsEntry
        let appName: String
        let kind: ChatCallKind
        /// The call started by itself (FaceTime, a Teams or Skype link); else you press call in the app.
        let direct: Bool
        /// The apps whose microphone means the call is on.
        let bundles: [String]
        var tracker: ChatCallTracker
    }

    @Published private(set) var call: Call?
    @Published private(set) var devices = ChatCallDevices()
    private var timer: Timer?
    private var reading = false

    static let interval: TimeInterval = 2

    func begin(entry: ChatsEntry, appName: String, kind: ChatCallKind, direct: Bool, bundles: [String]) {
        call = Call(entry: entry, appName: appName, kind: kind, direct: direct, bundles: bundles,
                    tracker: ChatCallTracker(started: Date()))
        ChatCallBadge.shared.show()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        read()
    }

    /// Stops following the call (the call itself goes on in its app).
    func dismiss() {
        timer?.invalidate()
        timer = nil
        call = nil
        ChatCallBadge.shared.hide()
    }

    /// Brings the app the call is in to the front.
    func showApp() {
        guard let call else { return }
        let running = NSWorkspace.shared.runningApplications.first { app in
            guard let id = app.bundleIdentifier else { return false }
            return call.bundles.contains { id == $0 || id.hasPrefix($0 + ".") } && app.activationPolicy == .regular
        }
        if let running {
            running.activate()
        } else {
            AppModel.shared.openChatApp(call.entry.app)
        }
    }

    private func read() {
        guard let bundles = call?.bundles, !reading else { return }
        reading = true
        Task.detached(priority: .utility) {
            let inCall = ChatCalls.holdsMicrophone(bundles, microphoneApps: QuietWatch.microphoneApps())
            let devices = ChatCallDevices.read()
            await MainActor.run { [weak self] in self?.apply(inCall: inCall, devices: devices) }
        }
    }

    private func apply(inCall: Bool, devices: ChatCallDevices) {
        reading = false
        guard var call else { return }
        let showing = call.tracker.observe(inCall: inCall, at: Date())
        guard showing else { return dismiss() }
        if call != self.call { self.call = call }
        if devices != self.devices { self.devices = devices }
    }
}
