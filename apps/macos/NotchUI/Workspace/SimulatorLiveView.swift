import SwiftUI
import AppKit
import QuartzCore
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers

/// The Simulator page: a simulator live, to touch, swipe, type into, rotate and press the
/// buttons of, with its settings a menu away; agents open it with device_open and drive it with agent-device. Without
/// the device tools (they need Node.js and one install) it falls back to pictures of the screen.
struct SimulatorView: View {
    @ObservedObject private var hub = DeviceHubService.shared
    @StateObject private var stream = SimulatorStream()
    @State private var chosen: String?
    @State private var opening = false
    @State private var error: String?
    @State private var showActions = false

    var body: some View {
        Group {
            switch hub.state {
            case .ready:
                live
            case .installing, .starting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(hub.state == .installing ? tr("sim.hub.installing") : tr("sim.hub.starting"))
                        .font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .needsInstall:
                VStack(alignment: .leading, spacing: 10) {
                    setupNotice(tr("sim.hub.installExplain"), button: tr("sim.hub.install")) { Task { await hub.install() } }
                    SimulatorSnapshotView()
                }
            case .unavailable(let reason), .failed(let reason):
                VStack(alignment: .leading, spacing: 10) {
                    setupNotice(reason, button: hub.state == .needsInstall ? nil : tr("sim.hub.retry")) { Task { await hub.prepare() } }
                    SimulatorSnapshotView()
                }
            case .idle:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await hub.prepare() }
        .onReceive(NotificationCenter.default.publisher(for: .nookOpenSimulator)) { note in
            if let udid = note.object as? String { choose(udid, alreadyOpen: true) }
        }
        .onDisappear { stream.stop() }
    }

    private func setupNotice(_ text: String, button: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.gen3").foregroundStyle(NookTheme.textTertiary)
            Text(text).font(NookTheme.font(12)).foregroundStyle(NookTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let button { Button(button, action: action).controlSize(.small) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card).fill(NookTheme.paper.opacity(0.04)))
    }

    // MARK: Live

    private var live: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("", selection: Binding<String?>(get: { chosen }, set: { if let id = $0 { choose(id) } })) {
                    ForEach(hub.devices) { device in
                        Text("\(device.name) · \(device.version)\(device.booted ? "" : " — " + tr("sim.off"))").tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                if opening { ProgressView().controlSize(.small) }
                Spacer()
                if chosen != nil { controls }
            }
            if let message = error ?? stream.problem ?? hub.problem {
                Text(message).font(NookTheme.font(11.5)).foregroundStyle(NookTheme.amber).fixedSize(horizontal: false, vertical: true)
            }
            ZStack {
                if chosen != nil, stream.frame != nil {
                    SimulatorScreen(stream: stream)
                } else if chosen != nil {
                    ProgressView()
                } else {
                    Text(hub.devices.isEmpty ? tr("sim.noDevices") : tr("sim.pick"))
                        .font(NookTheme.font(12.5)).foregroundStyle(NookTheme.textTertiary).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if chosen != nil {
                Text(stream.inputReady ? tr("sim.hint") : tr("sim.waitingInput"))
                    .font(NookTheme.font(11)).foregroundStyle(NookTheme.textTertiary)
            }
        }
        .onAppear {
            if chosen == nil, let booted = hub.devices.first(where: \.booted) { choose(booted.id) }
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            iconButton("house", tr("sim.home")) { stream.press(.home) }
            iconButton("square.stack", tr("sim.appSwitcher")) { stream.press(.appSwitcher) }
            iconButton("lock", tr("sim.lock")) { stream.press(.lock) }
            iconButton("rotate.right", tr("sim.rotate")) { stream.rotate() }
            iconButton("camera", tr("sim.screenshot")) { Task { await screenshot() } }
            iconButton("slider.horizontal.3", tr("sim.actions")) { showActions = true }
                .popover(isPresented: $showActions, arrowEdge: .bottom) {
                    if let udid = chosen { SimulatorActionsPanel(udid: udid).frame(width: 340) }
                }
            Menu {
                Button(tr("sim.shutdown")) {
                    guard let udid = chosen else { return }
                    stream.stop()
                    chosen = nil
                    Task { await hub.shutdown(udid) }
                }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func iconButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(NookTheme.font(12)).frame(width: 26, height: 24) }
            .buttonStyle(.borderless)
            .help(label)
            .accessibilityLabel(label)
    }

    /// Opens a simulator (booting it when it is off), then shows it live.
    private func choose(_ udid: String, alreadyOpen: Bool = false) {
        chosen = udid
        error = nil
        stream.stop()
        opening = true
        Task {
            do {
                if !alreadyOpen { try await hub.open(udid) } else { await hub.refreshDevices() }
                if chosen == udid { stream.start(udid) }
            } catch let failure {
                if chosen == udid { error = failure.localizedDescription }
            }
            opening = false
        }
    }

    /// The screen as a PNG on the clipboard, or saved where you choose (⌥-click).
    private func screenshot() async {
        guard let udid = chosen else { return }
        do {
            let png = try await hub.screenshot(udid)
            if NSEvent.modifierFlags.contains(.option) {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "Simulator.png"
                if panel.runModal() == .OK, let url = panel.url { try png.write(to: url) }
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
            }
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}

/// The live screen: the stream turned as the device is, and the mouse, trackpad and keyboard as touches and keys.
struct SimulatorScreen: NSViewRepresentable {
    @ObservedObject var stream: SimulatorStream

    func makeNSView(context: Context) -> SimulatorScreenView {
        let view = SimulatorScreenView()
        view.stream = stream
        stream.onVideo = { [weak view] chunk in view?.decode(chunk) }
        stream.onVideoReset = { [weak view] in view?.resetVideo() }
        // A new view on a stream already running has missed its setup: a fresh subscription sends it again.
        if stream.usesH264 { stream.resubscribeVideo() }
        return view
    }

    func updateNSView(_ view: SimulatorScreenView, context: Context) {
        view.stream = stream
        view.show(stream.usesH264 ? nil : stream.frame, config: stream.config)
    }

    static func dismantleNSView(_ view: SimulatorScreenView, coordinator: ()) {
        view.stream?.onVideo = nil
        view.stream?.onVideoReset = nil
    }
}

final class SimulatorScreenView: NSView {
    weak var stream: SimulatorStream?
    private let picture = CALayer()
    /// H.264 frames, decoded by the system (VideoToolbox) as they are enqueued.
    private let video = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var awaitingKeyframe = true
    private var decoding = false
    private var config: DeviceHub.ScreenConfig?
    private var imageSize = CGSize(width: 9, height: 19.5)
    private var pressedModifiers: Set<UInt16> = []
    private var scrollPoint: (x: Double, y: Double)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        picture.contentsGravity = .resize
        picture.magnificationFilter = .linear
        picture.cornerRadius = 18
        picture.masksToBounds = true
        layer?.addSublayer(picture)
        video.videoGravity = .resize
        video.cornerRadius = 18
        video.masksToBounds = true
        video.isHidden = true
        layer?.addSublayer(video)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ jpeg: Data?, config: DeviceHub.ScreenConfig?) {
        if self.config != config {
            self.config = config
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutPicture()
            CATransaction.commit()
        }
        guard !decoding, let jpeg, let image = NSImage(data: jpeg), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = cgImage
        layoutPicture()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutPicture()
        CATransaction.commit()
    }

    /// Turned only when the stream is the portrait framebuffer and the device is in landscape or upside down.
    private var rotation: Double {
        guard let config, imageSize.width <= imageSize.height else { return 0 }
        return config.orientation.degrees
    }

    /// The box the picture takes as shown, fitted in the view.
    private var displayRect: CGRect {
        let turned = abs(rotation) == 90
        let shown = turned ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        guard shown.width > 0, shown.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / shown.width, bounds.height / shown.height)
        let size = CGSize(width: shown.width * scale, height: shown.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func layoutPicture() {
        let rect = displayRect
        let turned = abs(rotation) == 90
        for shown in [picture, video] {
            shown.bounds = CGRect(x: 0, y: 0, width: turned ? rect.height : rect.width, height: turned ? rect.width : rect.height)
            shown.position = CGPoint(x: rect.midX, y: rect.midY)
            shown.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation * .pi / 180)))
        }
    }

    // MARK: H.264

    /// A new stream: nothing decoded yet, the picture (a still, or MJPEG) shows until the first frame.
    func resetVideo() {
        video.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        video.isHidden = true
        picture.isHidden = false
        format = nil
        awaitingKeyframe = true
        decoding = false
    }

    /// The decoder setup, then frames: from the first keyframe on, each enqueued to be shown at once. A setup the
    /// system cannot use, or a renderer that fails, switches this device to MJPEG; a renderer that falls behind asks for
    /// a fresh stream (which starts with a keyframe).
    func decode(_ chunk: AvccChunk) {
        switch chunk.kind {
        case .description:
            guard let configuration = AvcConfiguration(chunk.payload), let format = Self.format(configuration) else {
                stream?.decoderFailed()
                return
            }
            self.format = format
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            if dimensions.width > 0, dimensions.height > 0 { imageSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height)) }
            // New dimensions (after a rotation): the layers follow at once.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layoutPicture()
            CATransaction.commit()
            awaitingKeyframe = true
        case .keyframe, .delta:
            guard let format else { return }
            let key = chunk.kind == .keyframe
            if awaitingKeyframe {
                guard key else { return }
                awaitingKeyframe = false
            }
            let renderer = video.sampleBufferRenderer
            if renderer.status == .failed {
                stream?.decoderFailed()
                return
            }
            guard renderer.isReadyForMoreMediaData else {
                stream?.resubscribeVideo()
                return
            }
            guard let sample = Self.sample(chunk.payload, format: format, key: key) else { return }
            renderer.enqueue(sample)
            if !decoding {
                decoding = true
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                video.isHidden = false
                picture.isHidden = true
                layoutPicture()
                CATransaction.commit()
            }
        case .seed:
            break
        }
    }

    private static func format(_ configuration: AvcConfiguration) -> CMVideoFormatDescription? {
        let sets = configuration.sps + configuration.pps
        var format: CMVideoFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: Int32(configuration.nalLengthSize), formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }

    /// Pointers to each parameter set for the length of the call.
    private static func withPointers<T>(_ sets: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> T) -> T {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { pointerBuffer in
            sizes.withUnsafeBufferPointer { sizeBuffer in body(pointerBuffer.baseAddress!, sizeBuffer.baseAddress!) }
        }
    }

    /// One frame (AVCC length-prefixed NAL units, as serve-sim sends them) as a sample to show right away.
    private static func sample(_ payload: Data, format: CMVideoFormatDescription, key: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !key {
                CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    /// A point of the view as 0…1 of the picture as shown.
    private func normalized(_ event: NSEvent) -> (x: Double, y: Double)? {
        let point = convert(event.locationInWindow, from: nil)
        let rect = displayRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (Double((point.x - rect.minX) / rect.width), Double((point.y - rect.minY) / rect.height))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = normalized(event), (0...1).contains(point.x), (0...1).contains(point.y) else { return }
        stream?.touch(.begin, x: point.x, y: point.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let point = normalized(event) else { return }
        stream?.touch(.move, x: point.x, y: point.y)
    }

    override func mouseUp(with event: NSEvent) {
        guard let point = normalized(event) else { return }
        stream?.touch(.end, x: point.x, y: point.y)
    }

    /// Two fingers on the trackpad drag the screen, the way your finger would (serve-sim has no scrolling of its own).
    override func scrollWheel(with event: NSEvent) {
        let rect = displayRect
        guard rect.width > 0, rect.height > 0, event.hasPreciseScrollingDeltas else { return }
        if event.phase == .began || (scrollPoint == nil && event.phase == .changed) {
            guard let start = normalized(event) else { return }
            scrollPoint = start
            stream?.touch(.begin, x: start.x, y: start.y)
        }
        if var point = scrollPoint, event.phase == .changed {
            point.x += Double(event.scrollingDeltaX / rect.width)
            point.y += Double(event.scrollingDeltaY / rect.height)
            scrollPoint = point
            stream?.touch(.move, x: point.x, y: point.y)
        }
        if event.phase == .ended || event.phase == .cancelled, let point = scrollPoint {
            stream?.touch(.end, x: point.x, y: point.y)
            scrollPoint = nil
        }
    }

    override func keyDown(with event: NSEvent) {
        guard DeviceHub.forwardsKey(keyCode: event.keyCode, command: event.modifierFlags.contains(.command)) else {
            return super.keyDown(with: event)
        }
        if !event.isARepeat { stream?.key(down: true, keyCode: event.keyCode) }
    }

    override func keyUp(with event: NSEvent) {
        guard DeviceHub.forwardsKey(keyCode: event.keyCode, command: event.modifierFlags.contains(.command)) else {
            return super.keyUp(with: event)
        }
        stream?.key(down: false, keyCode: event.keyCode)
    }

    /// Shift, Control and Option as keys of their own (⌘ stays with the Mac).
    override func flagsChanged(with event: NSEvent) {
        let code = event.keyCode
        guard [0x38, 0x3C, 0x3B, 0x3E, 0x3A, 0x3D].contains(code) else { return super.flagsChanged(with: event) }
        if pressedModifiers.contains(code) {
            pressedModifiers.remove(code)
            stream?.key(down: false, keyCode: code)
        } else {
            pressedModifiers.insert(code)
            stream?.key(down: true, keyCode: code)
        }
    }
}

/// The simulator's settings: appearance, text size, contrast, location, an app's
/// permissions, opening a link, starting and stopping an app, and a push notification.
struct SimulatorActionsPanel: View {
    let udid: String
    @State private var bundleID = ""
    @State private var url = ""
    @State private var latitude = "52.3676"
    @State private var longitude = "4.9041"
    @State private var permission = SimulatorPermission.camera
    @State private var payload = #"{"aps":{"alert":{"title":"Nook","body":"Hello"}}}"#
    /// What is wrong with a field before an action can run; how the action went shows as a toast.
    @State private var result: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(tr("sim.action.appearance")).frame(width: 110, alignment: .leading)
                Button(tr("sim.action.light")) { run(.appearance(dark: false)) }
                Button(tr("sim.action.dark")) { run(.appearance(dark: true)) }
            }
            HStack {
                Text(tr("sim.action.textSize")).frame(width: 110, alignment: .leading)
                Menu(tr("sim.action.choose")) {
                    ForEach(SimulatorTextSize.allCases) { size in Button(tr("sim.textSize." + size.rawValue)) { run(.textSize(size)) } }
                }
                .fixedSize()
                Button(tr("sim.action.contrast")) { run(.increaseContrast(true)) }
                Button(tr("sim.action.contrastOff")) { run(.increaseContrast(false)) }
            }
            HStack {
                Text(tr("sim.action.location")).frame(width: 110, alignment: .leading)
                TextField("lat", text: $latitude).frame(width: 70)
                TextField("lon", text: $longitude).frame(width: 70)
                Button(tr("sim.action.set")) {
                    if let lat = Double(latitude), let lon = Double(longitude), (-90...90).contains(lat), (-180...180).contains(lon) {
                        run(.location(latitude: lat, longitude: lon))
                    } else { result = tr("sim.action.badLocation") }
                }
                Button(tr("sim.action.clear")) { run(.clearLocation) }
            }
            Divider()
            HStack {
                Text(tr("sim.action.app")).frame(width: 110, alignment: .leading)
                TextField("com.example.app", text: $bundleID).font(.system(.body, design: .monospaced))
            }
            HStack {
                Spacer().frame(width: 110)
                Button(tr("sim.action.launch")) { withBundle { run(.launch(bundleID: $0)) } }
                Button(tr("sim.action.terminate")) { withBundle { run(.terminate(bundleID: $0)) } }
            }
            HStack {
                Text(tr("sim.action.permission")).frame(width: 110, alignment: .leading)
                Picker("", selection: $permission) {
                    ForEach(SimulatorPermission.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
                Menu(tr("sim.action.choose")) {
                    ForEach(SimulatorPermissionDecision.allCases) { decision in
                        Button(tr("sim.permission." + decision.rawValue)) {
                            withBundle { run(.permission(permission, decision: decision, bundleID: $0)) }
                        }
                    }
                }
                .fixedSize()
            }
            HStack(alignment: .top) {
                Text(tr("sim.action.push")).frame(width: 110, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $payload).font(NookTheme.mono(11)).frame(height: 54)
                    Button(tr("sim.action.send")) { sendPush() }
                }
            }
            Divider()
            HStack {
                Text(tr("sim.action.openURL")).frame(width: 110, alignment: .leading)
                TextField("https://… / myapp://…", text: $url)
                Button(tr("sim.action.open")) {
                    let clean = url.trimmingCharacters(in: .whitespaces)
                    guard let parsed = URL(string: clean), parsed.scheme != nil, parsed.scheme != "file" else { result = tr("sim.action.badURL"); return }
                    run(.openURL(clean))
                }
            }
            if let result {
                Text(result).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .controlSize(.small)
        .padding(14)
    }

    private func withBundle(_ body: (String) -> Void) {
        let clean = bundleID.trimmingCharacters(in: .whitespaces)
        guard SimulatorAction.isValidBundleID(clean) else { result = tr("sim.action.badBundle"); return }
        body(clean)
    }

    private func sendPush() {
        withBundle { bundle in
            guard SimulatorAction.isValidPushPayload(payload) else { result = tr("sim.action.badPayload"); return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("nook-push-\(UUID().uuidString).apns")
            do { try Data(payload.utf8).write(to: file) } catch { result = error.localizedDescription; return }
            run(.push(bundleID: bundle, payloadFile: file.path)) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func run(_ action: SimulatorAction, then cleanup: (() -> Void)? = nil) {
        let udid = udid
        result = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) { Simulators.perform(action, udid: udid) }.value
            cleanup?()
            if let failure {
                ToastCenter.shared.error(tr("sim.action.failed"), detail: failure)
            } else {
                ToastCenter.shared.success(tr("sim.action.done"))
            }
        }
    }
}
