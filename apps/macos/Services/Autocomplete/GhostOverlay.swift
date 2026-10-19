import AppKit

/// The suggestion, drawn as a small grey pill next to the cursor with the key that accepts it. A panel that takes no clicks
/// and never becomes the key window, so typing carries on in the app underneath.
@MainActor
final class GhostOverlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byClipping
        hint.textColor = .tertiaryLabelColor
        hint.alignment = .right
        for view in [label, hint] { background.addSubview(view) }
        panel.contentView = background
    }

    func show(_ text: String, key: String, at caret: CGRect) {
        let size = max(11, min(18, caret.height * 0.72))
        label.font = .systemFont(ofSize: size)
        hint.font = .systemFont(ofSize: max(9, size - 3), weight: .medium)
        label.stringValue = text
        hint.stringValue = key
        label.sizeToFit()
        hint.sizeToFit()

        let height = max(caret.height, label.frame.height + 6)
        let width = label.frame.width + hint.frame.width + 22
        label.frame.origin = CGPoint(x: 8, y: (height - label.frame.height) / 2)
        hint.frame.origin = CGPoint(x: width - hint.frame.width - 8, y: (height - hint.frame.height) / 2)

        var origin = CGPoint(x: caret.maxX + 3, y: caret.minY + (caret.height - height) / 2)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: caret.maxX, y: caret.midY)) }) ?? NSScreen.main {
            origin.x = min(origin.x, screen.visibleFrame.maxX - width - 4)
        }
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
