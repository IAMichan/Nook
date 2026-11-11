import AVFoundation
import CoreAudio

/// The microphone, sound output and camera a call uses, as this Mac says: the microphone that is recording (else the
/// one macOS records from), where sound goes, and a camera that another app has on. Reading needs no permission: no
/// device is opened.
struct ChatCallDevices: Equatable, Sendable {
    var microphone: String?
    var speaker: String?
    /// The camera that is on, nil while none is.
    var camera: String?

    /// Read on a background queue while a call shows: each read is a few round trips to coreaudiod.
    static func read() -> ChatCallDevices {
        let inputs = audioDevices().filter { hasStreams($0, scope: kAudioObjectPropertyScopeInput) }
        let defaultInput = defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let running = inputs.filter(isRunning)
        let microphone = running.first { $0 == defaultInput } ?? running.first ?? defaultInput
        let camera = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                      mediaType: .video, position: .unspecified)
            .devices.first { $0.isInUseByAnotherApplication }
        return ChatCallDevices(microphone: microphone.flatMap(name), speaker: defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).flatMap(name),
                               camera: camera?.localizedName)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func audioDevices() -> [AudioObjectID] {
        var where_ = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var where_ = address(selector)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func hasStreams(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var where_ = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunning(_ device: AudioObjectID) -> Bool {
        var where_ = address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func name(_ device: AudioObjectID) -> String? {
        var where_ = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &where_, 0, nil, &size, $0) }
        guard status == noErr, let name else { return nil }
        let text = name.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }
}
