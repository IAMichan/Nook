import AppKit
import ApplicationServices

/// The window capture shortcut (Settings › Shortcuts): the front window's picture and its text, for the composer of the
/// session you work in or the Nook chat (`WindowCaptureTarget`). The picture comes from `WindowAttach.capture`, the text
/// from the window's accessibility tree when Nook may read it, else from the picture (`ScreenReader`).
@MainActor
enum WindowCapture {
    /// The front window of the app in front: Nook's own when Nook is in front.
    static func frontWindow() -> (target: WindowAttach.Target, pid: pid_t)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        let pid = app.processIdentifier
        // The list runs front to back: the first normal window of the app is the one you look at.
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.width > 80, rect.height > 60 else { continue }
            let frame = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
            return (WindowAttach.Target(windowID: id, app: app.localizedName ?? (info[kCGWindowOwnerName as String] as? String ?? ""),
                                        title: info[kCGWindowName as String] as? String ?? "", frame: frame), pid)
        }
        return nil
    }

    /// The window's text: its accessibility outline when Nook may read it and the app answers in time, else the words
    /// recognized in the picture.
    static func text(of pid: pid_t?, image: CGImage) async -> (text: String, source: WindowCaptureText.Source) {
        if let pid, AXIsProcessTrusted(), let tree = await accessibilityTree(pid) {
            let outline = WindowCaptureText.outline(tree)
            if !outline.isEmpty { return (outline, .accessibility) }
        }
        let recognized = (try? await ScreenReader.recognize(image)) ?? ""
        return (recognized, .recognized)
    }

    /// The focused window's accessibility tree, off the main thread; at most `nodeLimit` elements and `timeLimit` seconds,
    /// so a slow app costs a moment and not the capture.
    nonisolated static func accessibilityTree(_ pid: pid_t) async -> AXTextNode? {
        await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.25)
            guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else { return nil }
            var budget = nodeLimit
            let deadline = Date().addingTimeInterval(timeLimit)
            return node(window, depth: 0, budget: &budget, deadline: deadline)
        }.value
    }

    nonisolated static let nodeLimit = 3_000
    nonisolated static let timeLimit: TimeInterval = 1.5

    nonisolated private static func node(_ element: AXUIElement, depth: Int, budget: inout Int, deadline: Date) -> AXTextNode? {
        guard budget > 0, Date() < deadline else { return nil }
        budget -= 1
        var made = AXTextNode(role: string(element, kAXRoleAttribute))
        made.title = string(element, kAXTitleAttribute)
        made.value = string(element, kAXValueAttribute)
        made.label = string(element, kAXDescriptionAttribute)
        guard depth < 40 else { return made }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let list = children as? [AXUIElement] {
            for child in list {
                guard let built = node(child, depth: depth + 1, budget: &budget, deadline: deadline) else { break }
                made.children.append(built)
            }
        }
        return made
    }

    nonisolated private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    nonisolated private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        // Only words: a checkbox's 0 or 1 says nothing beside the picture.
        return value as? String ?? ""
    }
}
