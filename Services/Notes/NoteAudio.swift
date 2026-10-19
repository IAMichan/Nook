// The Notetaker's audio: your microphone and what the Mac plays (the other people of a call), as 16 kHz mono samples,
// kept in memory only until they are transcribed. Nothing is written to disk.
//
// MicCapture, SystemAudioTap and Resampler16k are adapted from open-source code under the MIT License, Copyright (c) 2026 Louis Raillé (see THIRD-PARTY-NOTICES.md).

import AudioToolbox
import AVFoundation
import CoreAudio
import os

/// One side of a call: the stretch not transcribed yet, and how loud it is now.
final class LiveChannel: @unchecked Sendable {
    static let sampleRate = 16_000.0

    private struct State {
        var pending: [Float] = []
        /// Where `pending` starts, in seconds from the start of the recording.
        var pendingStart = 0.0
        var total = 0
        var level: Float = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// From the audio thread.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let rms = Self.rms(samples[...])
        state.withLock { state in
            state.pending.append(contentsOf: samples)
            state.total += samples.count
            state.level = rms
        }
    }

    var level: Float { state.withLock { $0.level } }

    /// The stretch not transcribed yet, once it is long enough and ends on a pause (or has become too long to wait).
    /// Silent stretches are dropped without a word.
    func takeChunk(minSeconds: Double = 4, maxSeconds: Double = 25, force: Bool = false) -> (start: Double, samples: [Float])? {
        state.withLock { state -> (start: Double, samples: [Float])? in
            let seconds = Double(state.pending.count) / Self.sampleRate
            guard seconds >= (force ? 0.5 : minSeconds) else { return nil }
            let tail = state.pending.suffix(Int(Self.sampleRate / 2))
            guard force || Self.rms(tail) < 0.012 || seconds >= maxSeconds else { return nil }
            let chunk = (start: state.pendingStart, samples: state.pending)
            state.pendingStart = Double(state.total) / Self.sampleRate
            state.pending.removeAll(keepingCapacity: true)
            return Self.rms(chunk.samples[...]) < 0.004 ? nil : chunk
        }
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

// MARK: - Microphone

/// The microphone, as 16 kHz mono samples.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start(sink: @escaping @Sendable ([Float]) -> Void) -> Bool {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard let resampler = Resampler16k(from: format) else { return false }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            sink(resampler.convert(buffer))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0)
            return false
        }
        return true
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

// MARK: - The Mac's sound

/// Everything the Mac plays (the other people of a call, whatever the app), through a Core Audio
/// process tap (macOS 14.2+). macOS asks once for the "System Audio Recording" permission.
/// Nothing is muted: you keep hearing the call.
final class SystemAudioTap: @unchecked Sendable {
    enum TapError: LocalizedError {
        case failed(String, OSStatus)
        var errorDescription: String? {
            switch self {
            case .failed(let step, let status): return "\(step) (\(status))"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// The tap's own buffers, when the aggregate also brings the output device's inputs (a headset's mic).
    private var tapList: UnsafeMutableAudioBufferListPointer?
    private let queue = DispatchQueue(label: "nl.imdigital.nook.notetaker.system", qos: .userInitiated)

    func start(sink: @escaping @Sendable ([Float]) -> Void) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.name = "Nook Notetaker"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw TapError.failed("process tap", status) }
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var description16 = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &description16)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &description16),
              let resampler = Resampler16k(from: format) else {
            stop()
            throw TapError.failed("tap format", status)
        }

        let outputUID = try Self.defaultOutputUID()
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Nook Notetaker",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else {
            stop()
            throw TapError.failed("aggregate device", status)
        }
        aggregateID = device

        // The aggregate's input is the output device's own inputs (a headset's microphone), if it has
        // any, then the tap: the tap's buffers are the last ones.
        let tapBuffers = format.isInterleaved ? 1 : Int(format.channelCount)
        let scratch = AudioBufferList.allocate(maximumBuffers: tapBuffers)
        tapList = scratch
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, _, _ in
            let all = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var list = input
            if all.count > tapBuffers {
                for i in 0..<tapBuffers { scratch[i] = all[all.count - tapBuffers + i] }
                list = UnsafePointer(scratch.unsafePointer)
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list, deallocator: nil) else { return }
            sink(resampler.convert(buffer))
        }
        guard status == noErr, let proc else {
            stop()
            throw TapError.failed("io proc", status)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            throw TapError.failed("start", status)
        }
    }

    func stop() {
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        if let tapList { free(tapList.unsafeMutablePointer) }
        tapList = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private static func defaultOutputUID() throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != AudioObjectID(kAudioObjectUnknown) else { throw TapError.failed("output device", status) }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString
        size = UInt32(MemoryLayout<CFString>.stride)
        status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr else { throw TapError.failed("output device uid", status) }
        return uid as String
    }
}

// MARK: - 16 kHz mono

/// Turns the microphone's or the Mac's audio, in whatever format it comes, into the 16 kHz mono
/// Float32 samples Parakeet and the diarizer take. Fed from one audio thread at a time.
final class Resampler16k: @unchecked Sendable {
    nonisolated(unsafe) static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                          channels: 1, interleaved: false)!
    private let converter: AVAudioConverter
    private let ratio: Double

    init?(from input: AVAudioFormat) {
        guard input.sampleRate > 0, let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        converter.downmix = true
        self.converter = converter
        ratio = 16_000 / input.sampleRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return [] }
        nonisolated(unsafe) var fed = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, let data = out.floatChannelData, out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }
}
