// A window for throwaway AppKit/SwiftUI harnesses that the user can never see.
//
// Compile it next to your harness:
//
//     swiftc -O main.swift <checkout>/scripts/harness/OffscreenWindow.swift -o harness
//
// and host your view with it:
//
//     let window = OffscreenWindow.host(MyView(), size: CGSize(width: 400, height: 600))
//     OffscreenWindow.pump(0.5)
//     let png = OffscreenWindow.snapshot(window)   // a picture, without screen recording
//
// Why: `orderBack` puts a window behind the user's windows, still on their screen. It shows up the moment they close
// or move the window in front of it, scrolling and redrawing while the harness runs. This window is borderless (macOS
// does not move borderless windows back onto a screen), far outside every screen, never key, never in front, ignores
// the mouse, and the process stays out of the Dock. It exits the harness when the window ends up on a screen anyway.

import AppKit
import SwiftUI

@MainActor
enum OffscreenWindow {
    /// Far outside every screen arrangement macOS allows.
    static let origin = NSPoint(x: -30_000, y: -30_000)

    /// A borderless window far off screen with `view` in it, ordered in (behind everything) so SwiftUI lays out, appears
    /// and scrolls as it does on screen.
    static func host<Content: View>(_ view: Content, size: CGSize) -> NSWindow {
        host(NSHostingView(rootView: view), size: size)
    }

    static func host(_ view: NSView, size: CGSize) -> NSWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .normal
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.setFrameOrigin(origin)
        window.orderBack(nil)
        window.setFrameOrigin(origin)
        guardOffscreen(window)
        return window
    }

    /// Resizes the window, keeping it off screen.
    static func resize(_ window: NSWindow, to size: CGSize) {
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        guardOffscreen(window)
    }

    /// Runs the main run loop for `seconds`, so layout, `onAppear` and animations happen.
    static func pump(_ seconds: Double = 0.05) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }

    /// What the window shows, as PNG data, drawn from its layer: no screen capture, so no Screen Recording prompt.
    static func snapshot(_ window: NSWindow) -> Data? {
        guard let view = window.contentView else { return nil }
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0, let layer = view.layer,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The layer draws top-down; flip so the picture is the right way up.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Stops the harness when its window touches a screen: better a failed run than a window in the user's way.
    static func guardOffscreen(_ window: NSWindow) {
        let frame = window.frame
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }) {
            FileHandle.standardError.write(Data("OffscreenWindow: the window landed on a screen at \(frame); stopping.\n".utf8))
            window.orderOut(nil)
            exit(70)
        }
    }
}
