import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

/// A Mac app open next to the chat ("@open whatsapp" with WhatsApp installed). macOS does not let one app put another
/// app's window inside its own, so Nook shows a live picture of the real window (ScreenCaptureKit, 60 frames a second,
/// straight from the GPU into a layer, nothing copied) and passes your clicks, scrolling and typing on that picture to the
/// app. The real window stays where it is; with Accessibility it is sized to the pane, so the picture is sharp and 1:1.
@MainActor
final class MacAppMirror: ObservableObject {
    static let shared = MacAppMirror()

    enum Status: Equatable {
        case idle
        /// Starting the app and waiting for its window.
        case starting
        case needsScreenAccess
        case noWindow
        case showing
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// A short line over the picture: that clicking and typing need Accessibility.
    @Published private(set) var notice: String?
    /// Where the frames go; the pane's view hosts it.
    let layer: CALayer = {
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        return layer
    }()

    private(set) var app: EmbeddedApp?
    private var pid: pid_t?
    private var windowID: CGWindowID?
    /// The window's whole frame, and the part of it on its display that the picture shows. Top-left origin.
    private var fullFrame: CGRect = .zero
    private var shownFrame: CGRect = .zero
    private var displayID: CGDirectDisplayID?
    private var originalSize: CGSize?
    private var paneSize: CGSize = .zero
    private var stream: SCStream?
    private var sink: FrameSink?
    private var tracker: Timer?
    private var startTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var askedControl = false

    func open(_ app: EmbeddedApp) {
        if self.app?.id == app.id, status == .showing || status == .starting { return }
        close()
        self.app = app
        start()
    }

    func restart() {
        guard let app else { return }
        close()
        self.app = app
        start()
    }

    /// Stops the picture. The app itself keeps running, at the size it had before.
    func close() {
        startTask?.cancel()
        startTask = nil
        resizeTask?.cancel()
        tracker?.invalidate()
        tracker = nil
        stopStream()
        restoreSize()
        layer.contents = nil
        app = nil
        pid = nil
        windowID = nil
        fullFrame = .zero
        shownFrame = .zero
        originalSize = nil
        status = .idle
        notice = nil
    }

    /// The real app in front, for what the picture cannot do (dragging files, a full-screen video).
    func bringToFront() {
        if let pid, let running = NSRunningApplication(processIdentifier: pid) {
            _ = running.activate()
        } else if let app {
            NSWorkspace.shared.open(app.url)
        }
    }

    func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess() { SystemPermission.screen.openSettings() }
    }

    // MARK: Starting

    private func start() {
        guard let app else { return }
        notice = nil
        guard CGPreflightScreenCaptureAccess() else {
            status = .needsScreenAccess
            return
        }
        status = .starting
        startTask = Task { [weak self] in await self?.launch(app) }
    }

    private func launch(_ app: EmbeddedApp) async {
        let configuration = NSWorkspace.OpenConfiguration()
        // Nook stays in front: the app shows up in the pane, not over it.
        configuration.activates = false
        let running: NSRunningApplication
        do {
            running = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
        } catch {
            guard !Task.isCancelled, self.app?.id == app.id else { return }
            status = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled, self.app?.id == app.id else { return }
        pid = running.processIdentifier
        if running.isHidden { running.unhide() }
        await findWindow(tries: 25)
    }

    /// Waits for the app's main window (a freshly started app takes a moment), then shows it.
    private func findWindow(tries: Int) async {
        guard let pid else { return }
        for attempt in 0..<tries {
            if Task.isCancelled { return }
            if let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
               let window = Self.mainWindow(in: content, pid: pid) {
                await show(window, in: content)
                return
            }
            if attempt < tries - 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
        }
        if !Task.isCancelled { status = .noWindow }
    }

    /// The app's largest normal window on screen.
    private static func mainWindow(in content: SCShareableContent, pid: pid_t) -> SCWindow? {
        content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 120 && $0.frame.height > 120 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func show(_ window: SCWindow, in content: SCShareableContent) async {
        guard let pid, let owner = content.applications.first(where: { $0.processID == pid }),
              let display = content.displays.max(by: { Self.overlap($0.frame, window.frame) < Self.overlap($1.frame, window.frame) }) else {
            status = .noWindow
            return
        }
        let shown = window.frame.intersection(display.frame)
        guard !shown.isEmpty else {
            status = .noWindow
            return
        }
        windowID = window.windowID
        fullFrame = window.frame
        shownFrame = shown
        displayID = display.displayID
        // The whole app on that display, cut to the window: its menus and popovers over the window show up too, and
        // whatever lies on top of the real window (Nook itself) does not.
        let filter = SCContentFilter(display: display, including: [owner], exceptingWindows: [])
        let sink = FrameSink(layer: layer) { [weak self] in
            Task { @MainActor in self?.streamStopped() }
        }
        let stream = SCStream(filter: filter, configuration: configuration(for: shown, on: display.frame), delegate: sink)
        do {
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            try await stream.startCapture()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled, self.pid == pid else {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
        self.sink = sink
        status = .showing
        track()
        fitWindow()
    }

    private func configuration(for shown: CGRect, on display: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: shown.minX - display.minX, y: shown.minY - display.minY, width: shown.width, height: shown.height)
        let scale = backingScale
        configuration.width = max(2, Int(shown.width * scale))
        configuration.height = max(2, Int(shown.height * scale))
        // As smooth as the screen: a new frame whenever the app draws, up to 60 a second.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    private var backingScale: CGFloat {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }?.backingScaleFactor ?? 2
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let both = a.intersection(b)
        return both.isNull ? 0 : both.width * both.height
    }

    private func stopStream() {
        if let stream {
            Task { try? await stream.stopCapture() }
        }
        stream = nil
        sink = nil
    }

    /// The app quit or its window went away while showing.
    private func streamStopped() {
        guard status == .showing else { return }
        stopStream()
        tracker?.invalidate()
        status = .noWindow
    }

    // MARK: Following the window

    /// Twice a second: the window moved or resized (the picture follows), closed or went to another Space (find it again).
    private func track() {
        tracker?.invalidate()
        tracker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWindow() }
        }
    }

    private func checkWindow() {
        guard status == .showing, let windowID, let stream, let displayID else { return }
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
            // Closed, minimised or on another Space: look for its window again.
            stopStream()
            tracker?.invalidate()
            status = .starting
            startTask = Task { [weak self] in await self?.findWindow(tries: 6) }
            return
        }
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        guard frame != fullFrame else { return }
        let display = CGDisplayBounds(displayID)
        let shown = frame.intersection(display)
        guard !shown.isEmpty, shown.width > 40, shown.height > 40 else {
            // Moved to another display.
            restart()
            return
        }
        fullFrame = frame
        shownFrame = shown
        let configuration = configuration(for: shown, on: display)
        Task { try? await stream.updateConfiguration(configuration) }
    }

    // MARK: Sizing the real window

    /// The pane changed size: the real window follows once you stop dragging, so the picture stays sharp.
    func paneResized(_ size: CGSize) {
        guard size != paneSize else { return }
        paneSize = size
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.fitWindow()
        }
    }

    /// Makes the real window as big as the pane, kept on its display. Needs Accessibility; without it the picture is
    /// scaled to fit instead.
    private func fitWindow() {
        guard status == .showing, paneSize.width > 200, paneSize.height > 150, AXIsProcessTrusted(),
              let element = axWindow(), let displayID else { return }
        if originalSize == nil { originalSize = fullFrame.size }
        let display = CGDisplayBounds(displayID)
        var size = CGSize(width: min(paneSize.width.rounded(), display.width), height: min(paneSize.height.rounded(), display.height))
        var origin = CGPoint(x: min(max(fullFrame.minX, display.minX), display.maxX - size.width),
                             y: min(max(fullFrame.minY, display.minY), display.maxY - size.height))
        if origin != fullFrame.origin, let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        checkWindow()
    }

    private func restoreSize() {
        guard var size = originalSize, AXIsProcessTrusted(), let element = axWindow(),
              let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    /// The accessibility element of the shown window: the one at its position.
    private func axWindow() -> AXUIElement? {
        guard let pid else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { window in
            var position: CFTypeRef?
            var point = CGPoint.zero
            guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &position) == .success,
                  let position, CFGetTypeID(position) == AXValueGetTypeID(),
                  AXValueGetValue(position as! AXValue, .cgPoint, &point) else { return false }
            return abs(point.x - fullFrame.minX) < 4 && abs(point.y - fullFrame.minY) < 4
        }
    }

    // MARK: Clicking, scrolling and typing

    /// A mouse or scroll event on the picture, at `local` (top-left origin) in a pane of `size`, sent to the app at the
    /// same spot in its window. Moving the pointer is sent `quietly`: without permission it is dropped without a word.
    func forward(_ event: NSEvent, at local: CGPoint, in size: CGSize, quietly: Bool = false) {
        guard status == .showing, let pid,
              let point = MirrorGeometry.screenPoint(local, view: size, window: shownFrame),
              mayControl(quietly: quietly), let copy = event.cgEvent?.copy() else { return }
        copy.location = point
        if event.type != .scrollWheel {
            // The app's window under the point: a menu or popover of its own when one is open there.
            let pressed = event.type != .mouseMoved
            let target = Int64((pressed ? Self.window(at: point, pid: pid) : nil) ?? windowID ?? 0)
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: target)
            copy.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: target)
        }
        copy.postToPid(pid)
    }

    /// A key typed while the picture has focus, sent to the app as is (shortcuts included).
    func forwardKey(_ event: NSEvent) {
        guard status == .showing, let pid, mayControl(quietly: false), let copy = event.cgEvent?.copy() else { return }
        copy.postToPid(pid)
    }

    private func mayControl(quietly: Bool) -> Bool {
        if CGPreflightPostEventAccess() {
            if notice != nil { notice = nil }
            return true
        }
        guard !quietly else { return false }
        if !askedControl {
            askedControl = true
            _ = CGRequestPostEventAccess()
        }
        notice = tr("embedded.mac.control", app?.title ?? "")
        return false
    }

    /// The front-most window of the app containing the point (top-left origin).
    private static func window(at point: CGPoint, pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == pid {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if frame.contains(point) { return id }
        }
        return nil
    }

    // MARK: Reading

    /// What the app shows, as text, through Accessibility: for Nook to read when you ask about it.
    func text() async throws -> (title: String, url: String, text: String) {
        guard let app, let pid else { throw NookError(tr("embedded.nothingOpen")) }
        guard AppTextReader.hasPermission else {
            AppTextReader.requestPermission()
            throw NookError(tr("embedded.mac.noText", app.title))
        }
        AppTextReader.wake(pid: pid)
        let parts = await AppTextReader.text(pid: pid, limit: 14_000)
        let text = parts.map(\.text).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw NookError(tr("embedded.mac.noText", app.title)) }
        return (app.title, app.url.path, String(text.prefix(14_000)))
    }
}

/// Receives the frames on a queue of its own and puts each one in the layer as is: the frame's IOSurface becomes the
/// layer's contents, so nothing is copied or converted on the way.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "nook.embedded.mirror", qos: .userInteractive)
    private weak var layer: CALayer?
    private let onStop: () -> Void

    init(layer: CALayer, onStop: @escaping () -> Void) {
        self.layer = layer
        self.onStop = onStop
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = sampleBuffer.imageBuffer,
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        let layer = self.layer
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contents = surface
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop() }
}

/// The view under the picture: it takes the mouse and keyboard and hands them to the mirror.
final class MacAppMirrorView: NSView {
    private let mirror: MacAppMirror

    init(mirror: MacAppMirror) {
        self.mirror = mirror
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(mirror.layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        if mirror.layer.superlayer !== layer { layer?.addSublayer(mirror.layer) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mirror.layer.frame = bounds
        mirror.layer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        mirror.paneResized(bounds.size)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    /// The event's point in this view with the origin top left, as the app's window has it.
    private func pass(_ event: NSEvent, quietly: Bool = false) {
        let point = convert(event.locationInWindow, from: nil)
        mirror.forward(event, at: CGPoint(x: point.x, y: bounds.height - point.y), in: bounds.size, quietly: quietly)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pass(event)
    }
    override func mouseUp(with event: NSEvent) { pass(event) }
    override func mouseDragged(with event: NSEvent) { pass(event) }
    override func mouseMoved(with event: NSEvent) { pass(event, quietly: true) }
    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pass(event)
    }
    override func rightMouseUp(with event: NSEvent) { pass(event) }
    override func rightMouseDragged(with event: NSEvent) { pass(event) }
    override func otherMouseDown(with event: NSEvent) { pass(event) }
    override func otherMouseUp(with event: NSEvent) { pass(event) }
    override func scrollWheel(with event: NSEvent) { pass(event) }

    override func keyDown(with event: NSEvent) { mirror.forwardKey(event) }
    override func keyUp(with event: NSEvent) { mirror.forwardKey(event) }
    override func flagsChanged(with event: NSEvent) { mirror.forwardKey(event) }

    /// ⌘C, ⌘V and other shortcuts go to the app too while it has focus, not to Nook's menus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        mirror.forwardKey(event)
        return true
    }
}

private struct MacAppMirrorHost: NSViewRepresentable {
    let mirror: MacAppMirror

    func makeNSView(context: Context) -> MacAppMirrorView { MacAppMirrorView(mirror: mirror) }
    func updateNSView(_ view: MacAppMirrorView, context: Context) {}
}

/// The Mac app in the pane: its live picture, or what stands in its way (permission, no window yet).
struct MacAppMirrorPane: View {
    let app: EmbeddedApp
    @ObservedObject private var mirror = MacAppMirror.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            MacAppMirrorHost(mirror: mirror)
            switch mirror.status {
            case .showing:
                EmptyView()
            case .idle, .starting:
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(tr("embedded.mac.waiting", app.title))
                        .font(NookTheme.font(12.5))
                        .foregroundStyle(NookTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NookTheme.field)
            case .needsScreenAccess:
                WSEmptyState(symbol: "rectangle.dashed.badge.record", title: tr("embedded.mac.screenTitle", app.title),
                             message: tr("embedded.mac.screenDetail"), action: (tr("embedded.mac.openSettings"), { mirror.requestScreenAccess() }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NookTheme.field)
            case .noWindow:
                WSEmptyState(symbol: "macwindow", title: tr("embedded.mac.noWindow", app.title),
                             message: tr("embedded.mac.noWindowDetail"), action: (tr("embedded.reload"), { mirror.restart() }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NookTheme.field)
            case .failed(let message):
                WSEmptyState(symbol: "exclamationmark.triangle", title: tr("embedded.failed", app.title), message: message,
                             action: (tr("embedded.reload"), { mirror.restart() }))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(NookTheme.field)
            }
            if let notice = mirror.notice {
                Text(notice)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.paper)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
        }
    }
}
