import AppKit
import CoreAudio
import CoreGraphics

/// Reads whether you share your screen or sit in a meeting, for `QuietPolicy`: the windows on screen (a sharing bar,
/// a meeting site) and which apps have the microphone open. Reading needs no permission of its own; window names are
/// only known with Screen Recording, which Nook already asks for to read the screen.
@MainActor
enum QuietWatch {
    /// What is going on right now.
    static func situation(events: [CalEvent], useCalendar: Bool, recording: Bool, countScreenshots: Bool = true,
                          now: Date = Date()) -> QuietSituation {
        let windows = onScreenWindows()
        var meeting = QuietPolicy.MeetingSignals(now: now)
        meeting.events = events.map { QuietPolicy.Event(start: $0.start, end: $0.end) }
        meeting.useCalendar = useCalendar
        meeting.microphoneApps = microphoneApps()
        meeting.windowNames = windows.map(\.name).filter { !$0.isEmpty }
        meeting.recording = recording
        return QuietSituation(sharing: QuietPolicy.isSharing(windows, countSystemCapture: countScreenshots), meeting: QuietPolicy.isMeeting(meeting))
    }

    /// Every window on screen except Nook's own.
    static func onScreenWindows() -> [QuietPolicy.Window] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let own = ProcessInfo.processInfo.processIdentifier
        var bundles: [pid_t: String] = [:]
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own else { return nil }
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat]
            return QuietPolicy.Window(owner: info[kCGWindowOwnerName as String] as? String ?? "",
                                      bundleID: bundles[pid].flatMap { $0.isEmpty ? nil : $0 },
                                      name: info[kCGWindowName as String] as? String ?? "",
                                      height: Double(bounds?["Height"] ?? 0))
        }
    }

    /// Bundle IDs of the apps that have the microphone open right now, Nook itself left out.
    static func microphoneApps() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        let own = Bundle.main.bundleIdentifier ?? ""
        return objects.compactMap { object in
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(object, &inputAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { return nil }
            var idAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &nameRef) {
                AudioObjectGetPropertyData(object, &idAddress, 0, nil, &nameSize, $0)
            }
            guard status == noErr, let nameRef else { return nil }
            let bundleID = nameRef.takeRetainedValue() as String
            return bundleID.isEmpty || (!own.isEmpty && bundleID.hasPrefix(own)) ? nil : bundleID
        }
    }
}
