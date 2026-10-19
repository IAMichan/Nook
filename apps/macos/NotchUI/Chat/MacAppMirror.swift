import AppKit
import ApplicationServices
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SwiftUI

/// A Mac app open next to the chat ("@open whatsapp" with WhatsApp installed). macOS does not let one app put another
/// app's window inside its own, so Nook does the next best thing: it lays the real window exactly under the pane (with
/// Accessibility), shows a live picture of it in the pane (ScreenCaptureKit, 60 frames a second, straight from the GPU
/// into a layer, nothing copied), and lets the pointer fall through the notch onto the real window there. So you click,
/// scroll, drag and type in the app itself, with its own menus and cursor; only what you see is the picture.
/// Without Accessibility the window cannot be moved; then clicks on the picture are sent to the app as events instead,
/// which many apps ignore.
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
    /// The window's whole frame, and the part of the screen the picture shows: the screen under the pane once the window
    /// lies there, else the window itself. Top-left origin.
    private var fullFrame: CGRect = .zero
    private var shownFrame: CGRect = .zero
    private var displayID: CGDirectDisplayID?
    /// Where the window was before it went under the pane, to put it back on close.
    private var originalFrame: CGRect?
    private var axElement: AXUIElement?
    private var alignTarget: CGRect?
    private var alignTries = 0
    private var lastRaise = Date.distantPast
    /// The view showing the picture: where it is on screen is where the real window goes.
    weak var host: NSView?
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
        restoreFrame()
        layer.contents = nil
        app = nil
        pid = nil
        windowID = nil
        fullFrame = .zero
        shownFrame = .zero
        originalFrame = nil
        axElement = nil
        alignTarget = nil
        alignTries = 0
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
        if ScreenAccess.refused || !CGRequestScreenCaptureAccess() { SystemPermission.screen.openSettings() }
    }

    // MARK: Starting

    private func start() {
        guard let app else { return }
        notice = nil
        guard ScreenAccess.isUsable else {
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
            let content: SCShareableContent?
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            } catch {
                ScreenAccess.note(error)
                content = nil
            }
            // Refused: every further try would bring the system prompt back.
            if ScreenAccess.refused {
                status = .needsScreenAccess
                return
            }
            if let content, let window = Self.mainWindow(in: content, pid: pid) {
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
        if AXIsProcessTrusted() {
            alignWindow()
        } else {
            AppTextReader.requestPermission()
            notice = tr("embedded.mac.control", app?.title ?? "")
        }
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
            findAgain()
            return
        }
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        if frame != fullFrame {
            let onDisplay = frame.intersection(CGDisplayBounds(displayID))
            guard !onDisplay.isEmpty, onDisplay.width > 40, onDisplay.height > 40 else {
                // On another display now (the pane is there): capture that one.
                findAgain()
                return
            }
            // Moved away from under the pane (dragged by its title bar): it may go back.
            if underPane { alignTries = 0 }
            fullFrame = frame
        }
        // The pane moved or resized, or the window left it: put the window back under the pane. A few tries per spot,
        // so an app that refuses (a minimum size larger than the pane) is not pushed forever.
        if !aligned, let target = holeTarget {
            if target != alignTarget { alignTries = 0 }
            if alignTries < 3 { alignWindow() }
        }
        updateCapture(stream)
    }

    /// Points the capture at what the picture should show. With the window under the pane that is exactly the screen
    /// under the pane, 1:1, so every pixel of the picture is the pixel a click falls through to, even when the app is
    /// larger than the pane (a minimum size) and part of it sticks out. Otherwise it is the window, scaled into the pane.
    private func updateCapture(_ stream: SCStream) {
        guard let displayID else { return }
        let display = CGDisplayBounds(displayID)
        let shown = ((underPane ? holeTarget : nil) ?? fullFrame).intersection(display)
        guard !shown.isNull, shown.width > 2, shown.height > 2, shown != shownFrame else { return }
        shownFrame = shown
        let configuration = configuration(for: shown, on: display)
        Task { try? await stream.updateConfiguration(configuration) }
    }

    private func findAgain() {
        stopStream()
        tracker?.invalidate()
        status = .starting
        startTask = Task { [weak self] in await self?.findWindow(tries: 6) }
    }

    // MARK: The real window under the pane

    /// The picture on screen, in Cocoa coordinates (origin bottom left). Nil while the pane is not on screen.
    private var hole: CGRect? {
        guard let host, let window = host.window, window.isVisible, host.bounds.width > 0, host.bounds.height > 0 else { return nil }
        return window.convertToScreen(host.convert(host.bounds, to: nil))
    }

    /// The same, in the top-left coordinates windows have.
    private var holeTarget: CGRect? {
        guard let hole, let main = NSScreen.screens.first else { return nil }
        return CGRect(x: hole.minX.rounded(), y: (main.frame.height - hole.maxY).rounded(),
                      width: hole.width.rounded(), height: hole.height.rounded())
    }

    /// True when the real window starts at the pane's top-left corner. Its size may differ (an app with a minimum size
    /// larger than the pane): the picture then shows the part under the pane, and the pointer still lands right.
    var underPane: Bool {
        guard let target = holeTarget else { return false }
        return abs(fullFrame.minX - target.minX) < 2 && abs(fullFrame.minY - target.minY) < 2
    }

    /// True when the real window lies exactly under the picture, size included.
    private var aligned: Bool {
        guard let target = holeTarget else { return false }
        return abs(fullFrame.minX - target.minX) < 2 && abs(fullFrame.minY - target.minY) < 2
            && abs(fullFrame.width - target.width) < 2 && abs(fullFrame.height - target.height) < 2
    }

    /// The pane changed size: the window follows once you stop dragging.
    func paneResized(_ size: CGSize) {
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.checkWindow()
        }
    }

    /// Moves and sizes the real window to lie exactly under the pane. Needs Accessibility.
    private func alignWindow() {
        guard status == .showing, let target = holeTarget, target.width > 200, target.height > 150, AXIsProcessTrusted(),
              let element = axWindow() else { return }
        if originalFrame == nil { originalFrame = fullFrame }
        alignTarget = target
        alignTries += 1
        // Position, size, then position again: a window that grows past the screen edge is pushed back otherwise.
        Self.set(element, position: target.origin)
        Self.set(element, size: target.size)
        Self.set(element, position: target.origin)
        raise(activating: false)
        // Pick up the new frame right away instead of at the next tick, so the pointer can fall through sooner.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self?.checkWindow()
        }
    }

    private func restoreFrame() {
        guard let frame = originalFrame, AXIsProcessTrusted(), let element = axWindow() else { return }
        Self.set(element, size: frame.size)
        Self.set(element, position: frame.origin)
    }

    /// Puts the real window in front of other apps' windows, so the pointer lands on it under the pane. Activating also
    /// gives it the keyboard.
    func raise(activating: Bool) {
        guard let pid else { return }
        if let element = axWindow(), Date().timeIntervalSince(lastRaise) > 0.5 || activating {
            lastRaise = Date()
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        if activating, let running = NSRunningApplication(processIdentifier: pid) { _ = running.activate() }
    }

    /// Whether the notch should let the pointer through at `mouse` (Cocoa coordinates): over the picture, with the real
    /// window right under it and in front. If another app's window is in the way, the real window is raised first.
    func passesThrough(at mouse: NSPoint) -> Bool {
        guard status == .showing, underPane, let pid, let hole, hole.contains(mouse), let main = NSScreen.screens.first else { return false }
        if Self.isFront(pid, at: CGPoint(x: mouse.x, y: main.frame.height - mouse.y)) { return true }
        raise(activating: false)
        return false
    }

    /// True when `mouse` (Cocoa coordinates) is over the picture: a click there is in the app, not outside Nook.
    func holds(_ mouse: NSPoint) -> Bool {
        status == .showing && (hole?.contains(mouse) ?? false)
    }

    /// Whether the front-most window at the point (top-left coordinates) is the app's: a normal window, or a menu or
    /// popover of the app itself. Nook's own windows and other apps' overlays (above normal windows) are looked past.
    private static func isFront(_ pid: pid_t, at point: CGPoint) -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner != own,
                  owner == pid || (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if frame.contains(point) { return owner == pid }
        }
        return false
    }

    /// The accessibility element of the shown window: the one at its position, kept once found.
    private func axWindow() -> AXUIElement? {
        guard let pid else { return nil }
        if let axElement, Self.position(of: axElement) != nil { return axElement }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        axElement = windows.first { window in
            guard let point = Self.position(of: window) else { return false }
            return abs(point.x - fullFrame.minX) < 4 && abs(point.y - fullFrame.minY) < 4
        }
        return axElement
    }

    private static func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func set(_ element: AXUIElement, position: CGPoint) {
        var position = position
        if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
    }

    private static func set(_ element: AXUIElement, size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
    }

    // MARK: Clicking, scrolling and typing

    /// A click that reached the picture instead of the window under it. With the window under the pane, another app's
    /// window was in the way: bring the app forward, the next click lands. Otherwise send it as an event.
    func pressed(_ event: NSEvent, at local: CGPoint, in size: CGSize) {
        if underPane { raise(activating: true) } else { forward(event, at: local, in: size) }
    }

    /// A mouse or scroll event on the picture, at `local` (top-left origin) in a pane of `size`, sent to the app at the
    /// same spot in its window: the fallback without Accessibility. Moving the pointer is sent `quietly`: without
    /// permission it is dropped without a word.
    func forward(_ event: NSEvent, at local: CGPoint, in size: CGSize, quietly: Bool = false) {
        // The window lies under the pane but something is in front of it there: raise it, so the next move, scroll or
        // click falls through onto it.
        if status == .showing, underPane { return raise(activating: false) }
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
        guard status == .showing, !underPane, let pid, mayControl(quietly: false), let copy = event.cgEvent?.copy() else { return }
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
        mirror.host = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { mirror.host = self }
    }

    override func layout() {
        super.layout()
        if mirror.layer.superlayer !== layer { layer?.addSublayer(mirror.layer) }
        mirror.host = self
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
        let point = convert(event.locationInWindow, from: nil)
        mirror.pressed(event, at: CGPoint(x: point.x, y: bounds.height - point.y), in: bounds.size)
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
