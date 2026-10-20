import AppKit
import Quartz

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
