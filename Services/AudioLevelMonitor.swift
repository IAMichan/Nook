import Foundation
import CoreAudio
import AudioToolbox

/// Real audio levels of the music player, for the equalizer bars.
///
/// Taps the output of Spotify or Music with a Core Audio process tap (macOS 14.2+), splits the signal into
/// `bandCount` frequency bands and keeps a smoothed level (0…1) per band. The tap only listens: the player's
/// own sound is untouched. macOS asks permission for it the first time (`NSAudioCaptureUsageDescription`).
/// When the tap cannot start or is denied, all levels stay 0: bars rest instead of showing made-up movement.
final class AudioLevelMonitor: @unchecked Sendable {
    static let shared = AudioLevelMonitor()
    static let bandCount = 4

    /// Centre frequencies (Hz) of the bands: bass, low-mid, mid, treble.
    private static let centres: [Double] = [90, 420, 1800, 7000]
    private static let queue = DispatchQueue(label: "nl.imdigital.nook.audiolevels", qos: .userInteractive)

    private let lock = NSLock()
    private var levels = [Float](repeating: 0, count: AudioLevelMonitor.bandCount)
    private var lastSignal = Date.distantPast

    private var bundlePrefix: String?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var filters: [Biquad] = []

    // MARK: Reading

    /// Smoothed level of one band, 0…1. Falls to 0 when no audio arrived recently.
    func level(_ band: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard band >= 0, band < levels.count, Date().timeIntervalSince(lastSignal) < 0.5 else { return 0 }
        return Double(levels[band])
    }

    // MARK: Start and stop

    /// Follows the player with this bundle ID (or its helpers). Calling again with the same player is cheap.
    func start(bundleID: String) {
        Self.queue.async { [self] in
            if tapID != kAudioObjectUnknown, bundlePrefix == bundleID { return }
            teardown()
            bundlePrefix = bundleID
            setUp(bundleID: bundleID)
        }
    }

    func stop() {
        Self.queue.async { [self] in
            teardown()
            bundlePrefix = nil
        }
    }

    private func setUp(bundleID: String) {
        let processes = Self.audioProcesses(bundlePrefix: bundleID)
        guard !processes.isEmpty else { return }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return }

        var streamFormat = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &formatSize, &streamFormat) == noErr,
              streamFormat.mSampleRate > 0
        else {
            AudioHardwareDestroyProcessTap(tap)
            return
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nook levels",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        if let output = Self.defaultOutputUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return
        }

        let rate = streamFormat.mSampleRate
        filters = Self.centres.map { Biquad(bandpassAt: $0, sampleRate: rate, q: 1.1) }
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, Self.queue) { [weak self] _, input, _, _, _ in
            self?.process(input, sampleRate: rate)
        }
        guard status == noErr, let proc, AudioDeviceStart(device, proc) == noErr else {
            if let proc { AudioDeviceDestroyIOProcID(device, proc) }
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return
        }
        tapID = tap
        aggregateID = device
        procID = proc
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        lock.lock()
        levels = [Float](repeating: 0, count: Self.bandCount)
        lastSignal = .distantPast
        lock.unlock()
    }

    // MARK: Analysis

    /// Runs on the audio queue for each buffer (about every 10 ms).
    private func process(_ input: UnsafePointer<AudioBufferList>, sampleRate: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mDataByteSize > 0 else { return }
        var energy = [Float](repeating: 0, count: Self.bandCount)
        var frames = 0

        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            frames = max(frames, count)
            for n in 0..<count {
                var mono: Float = 0
                for c in 0..<channels { mono += data[n * channels + c] }
                mono /= Float(channels)
                for b in 0..<Self.bandCount {
                    let y = filters[b].run(mono)
                    energy[b] += y * y
                }
            }
        }
        guard frames > 0 else { return }

        // Time-based release so the bars fall the same speed whatever the buffer size.
        let dt = Float(Double(frames) / sampleRate)
        let release = expf(-dt / 0.14)
        lock.lock()
        for b in 0..<Self.bandCount {
            let rms = sqrtf(energy[b] / Float(frames))
            // −52…−10 dB onto 0…1. Higher bands carry less energy in music, so lift them a little.
            let db = 20 * log10f(rms + 1e-7) + Float(b) * 3
            let target = min(1, max(0, (db + 52) / 42))
            levels[b] = target > levels[b] ? levels[b] + (target - levels[b]) * 0.6 : max(target, levels[b] * release)
        }
        if energy.contains(where: { $0 > 1e-10 }) { lastSignal = Date() }
        lock.unlock()
    }

    // MARK: Core Audio lookups

    /// Audio process objects whose bundle ID is the player or one of its helpers.
    private static func audioProcesses(bundlePrefix: String) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects.filter { object in
            var idAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            let status = withUnsafeMutablePointer(to: &name) {
                AudioObjectGetPropertyData(object, &idAddress, 0, nil, &nameSize, $0)
            }
            return status == noErr && (name as String).hasPrefix(bundlePrefix)
        }
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0)
        }
        return status == noErr ? uid as String : nil
    }
}

/// Band-pass filter (RBJ cookbook, constant 0 dB peak gain), direct form I.
private final class Biquad {
    private let b0: Float, b2: Float, a1: Float, a2: Float
    private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    init(bandpassAt frequency: Double, sampleRate: Double, q: Double) {
        let w = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        b0 = Float(alpha / a0)
        b2 = Float(-alpha / a0)
        a1 = Float(-2 * cos(w) / a0)
        a2 = Float((1 - alpha) / a0)
    }

    func run(_ x: Float) -> Float {
        let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}
