import AppKit
import CoreAudio
import Foundation

/// Where the music sounds, and the switch to send it somewhere else: the Mac's own outputs (Core Audio, the same list as
/// the Sound settings) for both players, plus the playing player's own devices elsewhere: Music's AirPlay devices
/// (AppleScript) and Spotify Connect (`SpotifyWebAPI`, once Spotify is connected in Settings).
///
/// Idle it costs nothing: Core Audio tells Nook when a device comes or goes or the output changes, and the players are
/// only asked when the Music page shows the output button or its list opens.
@MainActor
final class MusicOutputService: ObservableObject {
    static let shared = MusicOutputService()

    /// This Mac's outputs, the one in use first.
    @Published private(set) var mac: [MusicOutput] = []
    /// The playing player's devices elsewhere (AirPlay in Music, Spotify Connect), this Mac left out.
    @Published private(set) var elsewhere: [MusicOutput] = []
    /// The player `elsewhere` came from.
    @Published private(set) var elsewhereApp: String?
    /// Spotify plays, but is not connected in Settings: its devices elsewhere cannot be read.
    @Published private(set) var needsSpotify = false
    @Published private(set) var loading = false
    /// The output being switched to, shown as chosen until the player or the Mac says so.
    @Published private(set) var switching: String?

    /// This Mac's name, as Spotify calls its device here.
    nonisolated static var macName: String { MachineName.local }

    private var listening = false
    private var listener: AudioObjectPropertyListenerBlock?
    private var lastPlayerRead = Date.distantPast

    /// Where the sound goes now: a device elsewhere the player sends to wins over the Mac's own output.
    var current: MusicOutput? { MusicOutputs.current(mac: mac, elsewhere: elsewhere) }

    /// Starts following the Mac's outputs (once) and reads the player's devices when they are older than a few seconds.
    func follow(app: String?) {
        startListening()
        if mac.isEmpty { refreshMac() }
        if app != elsewhereApp || Date().timeIntervalSince(lastPlayerRead) > 8 { refreshPlayer(app: app) }
    }

    /// Reads everything again: when the list opens.
    func refresh(app: String?) {
        refreshMac()
        refreshPlayer(app: app)
    }

    // MARK: Choosing

    /// Sends the music to `output`. On this Mac it also takes the player back from a device elsewhere.
    func select(_ output: MusicOutput, app: String?) {
        guard !output.active || !elsewhere.filter(\.active).isEmpty else { return }
        switching = output.id
        switch output.route {
        case .mac(let device):
            Task.detached(priority: .userInitiated) {
                let done = MusicOutputService.setDefaultOutput(device)
                await MainActor.run {
                    if !done { ToastCenter.shared.error(tr("music.output.failed"), detail: output.name) }
                }
            }
            bringBack(app: app)
        case .airPlay(let name):
            runMusic(MusicOutputs.selectAirPlayScript([name]), failure: output.name)
        case .spotify(let device):
            Task { @MainActor [weak self] in
                do {
                    try await SpotifyWebAPI.transfer(to: device)
                } catch {
                    ToastCenter.shared.error(tr("music.output.failed"), detail: NowPlayingService.message(for: error))
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.refreshPlayer(app: app)
            }
        }
        // The Mac tells Nook itself; the players are read again a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            Task { @MainActor in self?.switching = nil }
        }
    }

    /// Picking a speaker of this Mac while the player sends elsewhere: the player comes back to this Mac.
    private func bringBack(app: String?) {
        guard elsewhere.contains(where: \.active) else { return }
        switch app {
        case "Music":
            runMusic(MusicOutputs.selectAirPlayScript([]), failure: Self.macName)
        case "Spotify":
            Task { @MainActor [weak self] in
                guard let devices = try? await SpotifyWebAPI.devices(),
                      let mac = MusicOutputs.spotifyThisMac(devices, macName: Self.macName),
                      case .spotify(let id) = mac.route else {
                    ToastCenter.shared.info(tr("music.output.openSpotify"))
                    return
                }
                try? await SpotifyWebAPI.transfer(to: id)
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.refreshPlayer(app: app)
            }
        default:
            break
        }
    }

    private func runMusic(_ script: String, failure name: String) {
        NowPlayingService.libraryQueue.async { [weak self] in
            let result = NowPlayingService.runPlayerScript(script)
            Task { @MainActor in
                if result.text == nil, result.errorNumber != nil {
                    ToastCenter.shared.error(tr("music.output.failed"), detail: name)
                }
                self?.refreshPlayer(app: "Music")
            }
        }
    }

    // MARK: Reading

    /// Core Audio answers off the main thread, the list changes on it.
    private func refreshMac() {
        Task.detached(priority: .utility) { [weak self] in
            let outputs = MusicOutputService.macOutputs()
            await self?.applyMac(outputs)
        }
    }

    private func applyMac(_ outputs: [MusicOutput]) {
        if mac != outputs { mac = outputs }
        if let switching, outputs.contains(where: { $0.id == switching && $0.active }) { self.switching = nil }
    }

    private func refreshPlayer(app: String?) {
        lastPlayerRead = Date()
        if elsewhereApp != app {
            elsewhereApp = app
            elsewhere = []
        }
        switch app {
        case "Music":
            needsSpotify = false
            loading = elsewhere.isEmpty
            NowPlayingService.libraryQueue.async { [weak self] in
                let result = NowPlayingService.runPlayerScript(MusicOutputs.airPlayScript, cacheKey: "music.airplay.v1")
                let devices = result.text.map(MusicOutputs.airPlayDevices) ?? []
                Task { @MainActor in self?.apply(devices, from: "Music") }
            }
        case "Spotify":
            guard SpotifySignIn.shared.isSignedIn else {
                needsSpotify = true
                apply([], from: "Spotify")
                return
            }
            needsSpotify = false
            loading = elsewhere.isEmpty
            Task { @MainActor [weak self] in
                let devices = (try? await SpotifyWebAPI.devices()) ?? []
                self?.apply(MusicOutputs.elsewhere(devices, macName: Self.macName), from: "Spotify")
            }
        default:
            needsSpotify = false
            apply([], from: nil)
        }
    }

    private func apply(_ devices: [MusicOutput], from app: String?) {
        loading = false
        guard elsewhereApp == app else { return }
        if elsewhere != devices { elsewhere = devices }
        if let switching, devices.contains(where: { $0.id == switching && $0.active }) { self.switching = nil }
    }

    // MARK: Core Audio

    /// Core Audio says when a device comes or goes, or the output changes: the list follows without asking.
    private func startListening() {
        guard !listening else { return }
        listening = true
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refreshMac() }
        }
        listener = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block)
        }
    }

    nonisolated static func macOutputs() -> [MusicOutput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        let current = defaultOutput()
        let outputs: [MusicOutput] = devices.compactMap { device in
            guard hasOutput(device), number(kAudioDevicePropertyIsHidden, of: device) != 1, let name = deviceName(device) else { return nil }
            let transport = number(kAudioDevicePropertyTransportType, of: device) ?? 0
            let active = device == current
            guard MusicOutputs.listsMacOutput(transport: transport, active: active) else { return nil }
            return MusicOutput(route: .mac(device), name: name, kind: MusicOutputs.macKind(transport: transport, name: name), active: active)
        }
        return MusicOutputs.sorted(outputs)
    }

    nonisolated static func defaultOutput() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// Makes `device` the Mac's sound output, as choosing it in the Sound settings does.
    nonisolated static func setDefaultOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = device
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    private nonisolated static func hasOutput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private nonisolated static func number(_ selector: AudioObjectPropertySelector, of device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func deviceName(_ device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var nameRef: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &nameRef) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let nameRef else { return nil }
        let name = nameRef.takeRetainedValue() as String
        return name.isEmpty ? nil : name
    }
}
