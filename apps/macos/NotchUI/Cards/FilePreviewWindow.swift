import AppKit
import Quartz
import AVKit

/// A file shown on this Mac without leaving Nook: Quick Look in a window of its own (photos, PDFs, documents, video and
/// audio all play or show there), with a button that opens it in the app the Mac uses for it.
@MainActor
final class FilePreviewWindow: NSObject, NSWindowDelegate {
    static let shared = FilePreviewWindow()

    private var window: NSWindow?
    private var preview: QLPreviewView?
    private var shown: URL?

    /// Shows the file; false when Quick Look is not available, so the caller can open it another way.
    @discardableResult
    func show(_ url: URL, title: String) -> Bool {
        guard let window = window ?? make(), let preview = self.preview else { return false }
        shown = url
        preview.previewItem = url as NSURL
        window.title = title
        if !window.isVisible { window.center() }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func make() -> NSWindow? {
        let frame = NSRect(x: 0, y: 0, width: 720, height: 540)
        guard let preview = QLPreviewView(frame: frame, style: .normal) else { return nil }
        preview.autoresizingMask = [.width, .height]
        preview.shouldCloseWithWindow = false

        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.minSize = NSSize(width: 320, height: 240)
        window.delegate = self
        window.contentView = preview

        let open = NSButton(title: tr("card.attachment.open"), target: self, action: #selector(openInApp))
        open.bezelStyle = .accessoryBarAction
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = NSView(frame: NSRect(x: 0, y: 0, width: open.fittingSize.width + 12, height: 28))
        open.frame.origin = NSPoint(x: 0, y: (28 - open.fittingSize.height) / 2)
        open.setFrameSize(open.fittingSize)
        accessory.view.addSubview(open)
        window.addTitlebarAccessoryViewController(accessory)

        self.window = window
        self.preview = preview
        return window
    }

    @objc private func openInApp() {
        guard let shown else { return }
        if NSWorkspace.shared.open(shown) { window?.close() }
    }

    /// A closed window stops what plays in it.
    func windowWillClose(_ notification: Notification) {
        preview?.previewItem = nil
        shown = nil
    }
}

/// A video big, in a window of its own: the system's player, sized to the video, that resizes freely and goes full
/// screen (from its controls, the green button or a double-click on the picture).
@MainActor
final class VideoWindow: NSObject, NSWindowDelegate {
    static let shared = VideoWindow()

    private var window: NSWindow?
    private var playerView: AVPlayerView?

    /// Plays the video from `time`, in a window that fits it on the screen with the notch.
    func show(_ url: URL, title: String, at time: CMTime = .zero, aspect: CGSize? = nil) {
        let (window, view) = existing() ?? make()
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        window.title = title
        if !window.styleMask.contains(.fullScreen) { window.setFrame(frame(for: aspect, on: window.screen), display: true) }
        if let aspect, aspect.width > 0, aspect.height > 0 {
            window.contentAspectRatio = aspect
        } else {
            window.resizeIncrements = NSSize(width: 1, height: 1)   // no ratio known: resizes freely
        }
        if time.isValid, time.seconds > 0 {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.play()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func existing() -> (NSWindow, AVPlayerView)? {
        guard let window, let playerView else { return nil }
        return (window, playerView)
    }

    private func make() -> (NSWindow, AVPlayerView) {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        view.autoresizingMask = [.width, .height]

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = .black
        window.minSize = NSSize(width: 320, height: 180)
        window.delegate = self
        window.contentView = view
        window.togglesFullScreenOnDoubleClick(in: view)

        self.window = window
        self.playerView = view
        return (window, view)
    }

    /// The video as large as fits in three quarters of the screen, centered, never smaller than the minimum.
    private func frame(for aspect: CGSize?, on screen: NSScreen?) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ratio = aspect.flatMap { $0.width > 0 && $0.height > 0 ? $0.width / $0.height : nil } ?? 16 / 9
        var width = visible.width * 0.75
        var height = width / ratio
        if height > visible.height * 0.75 {
            height = visible.height * 0.75
            width = height * ratio
        }
        width = max(width, 320)
        height = max(height, 180)
        let content = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        return window?.frameRect(forContentRect: content) ?? content
    }

    /// A closed window stops what plays in it.
    func windowWillClose(_ notification: Notification) {
        playerView?.player?.pause()
        playerView?.player = nil
    }
}

private extension NSWindow {
    /// A double-click on the picture toggles full screen, as in QuickTime.
    func togglesFullScreenOnDoubleClick(in view: NSView) {
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleFullScreen(_:)))
        click.numberOfClicksRequired = 2
        click.delaysPrimaryMouseButtonEvents = false
        view.addGestureRecognizer(click)
    }
}
