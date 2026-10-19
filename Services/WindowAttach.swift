import AppKit
import ScreenCaptureKit
import SwiftUI

/// Hold ⌥ and drag Nook onto any window: a halo shows which one, and when you let go a picture of that window (and the
/// text in it) is attached to the chat, so you can ask about it. In Nook the orb does it.
@MainActor
final class WindowAttach {
    static let shared = WindowAttach()

    struct Target: Equatable {
        var windowID: CGWindowID
        var app: String
        var title: String
        /// In Cocoa coordinates (origin bottom left of the main screen).
        var frame: CGRect
    }

    /// The window was dropped on: picture, app name and window title.
    var onAttach: ((CGImage, Target) -> Void)?
    var onFailure: ((String) -> Void)?

    private(set) var isDragging = false
    private var target: Target?
    private var halo: NSPanel?

    func dragMoved() {
        isDragging = true
        let found = Self.window(at: NSEvent.mouseLocation)
        guard found != target else { return }
        target = found
        if let found { showHalo(found.frame) } else { halo?.orderOut(nil) }
    }

    func dragEnded() {
        isDragging = false
        halo?.orderOut(nil)
        guard let target else { return }
        self.target = nil
        Task { @MainActor in
            guard CGPreflightScreenCaptureAccess() else {
                _ = CGRequestScreenCaptureAccess()
                onFailure?(tr("chat.capture.permission"))
                return
            }
            guard let image = await Self.capture(target.windowID) else {
                onFailure?(tr("attach.window.failed", target.app))
                return
            }
            onAttach?(image, target)
        }
    }

    // MARK: Finding the window

    /// The front-most normal window under the point, not Nook's own.
    static func window(at point: NSPoint) -> Target? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        // Window bounds are in Quartz coordinates: origin top left of the main screen.
        let quartz = CGPoint(x: point.x, y: mainHeight - point.y)
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != own,
                  let boundsInfo = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let bounds = CGRect(x: boundsInfo["X"] ?? 0, y: boundsInfo["Y"] ?? 0, width: boundsInfo["Width"] ?? 0, height: boundsInfo["Height"] ?? 0)
            guard bounds.contains(quartz), bounds.width > 80, bounds.height > 60 else { continue }
            let frame = CGRect(x: bounds.minX, y: mainHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return Target(windowID: id, app: info[kCGWindowOwnerName as String] as? String ?? "",
                          title: info[kCGWindowName as String] as? String ?? "", frame: frame)
        }
        return nil
    }

    static func capture(_ windowID: CGWindowID) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(ChatImage.maxSide) / max(window.frame.width, window.frame.height)
        configuration.width = Int(window.frame.width * min(2, max(scale, 0.5)))
        configuration.height = Int(window.frame.height * min(2, max(scale, 0.5)))
        configuration.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                           configuration: configuration)
    }

    // MARK: The halo

    private func showHalo(_ frame: CGRect) {
        let panel = halo ?? Self.makeHalo()
        halo = panel
        panel.setFrame(frame.insetBy(dx: -4, dy: -4), display: true)
        panel.orderFrontRegardless()
    }

    private static func makeHalo() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: WindowHalo())
        return panel
    }
}

/// A soft rainbow ring around the window Nook will look at.
private struct WindowHalo: View {
    @State private var turn = 0.0

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                AngularGradient(colors: [Color(hex: 0xFF6B5B), Color(hex: 0xF7B32B), Color(hex: 0x2DD4A7), Color(hex: 0x38BDF8),
                                         Color(hex: 0xA78BFA), Color(hex: 0xF472B6), Color(hex: 0xFF6B5B)],
                                center: .center, angle: .degrees(turn)),
                lineWidth: 4
            )
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .onAppear { withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) { turn = 360 } }
    }
}
