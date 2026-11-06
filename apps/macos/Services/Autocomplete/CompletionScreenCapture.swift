import AppKit
import ScreenCaptureKit

/// Reads the text around a field from a picture of its window, on this Mac: what the conversation or mail above the field says.
/// Accurate recognition on the sharp picture: the fast level Nook's background screen reading uses is fine for finding a window
/// again, but makes "de offerte" of Dutch text "d8 off8rt8", which sends the model elsewhere. The picture itself is not kept.
enum CompletionScreenCapture {
    /// The text in the field's column of the app's window; nil when the picture gives none. `field` is in AppKit screen
    /// coordinates (origin bottom left).
    static func text(pid: pid_t, field: CGRect?, own: String) async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = window(of: pid, around: field, in: content.windows) else { return nil }
            let configuration = SCStreamConfiguration()
            // Twice the points: text as sharp as a Retina display shows it, which recognition reads far better.
            configuration.width = min(Int(window.frame.width * 2), maxSide)
            configuration.height = min(Int(window.frame.height * 2), maxSide)
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            let lines = try await ScreenReader.recognizeLines(image).map { line in
                CompletionScreenColumn.Line(text: line.text, box: CGRect(x: line.box.minX, y: 1 - line.box.maxY, width: line.box.width, height: line.box.height))
            }
            let text = CompletionScreenColumn.text(lines, field: field.flatMap { part(of: window.frame, field: $0) }, own: own)
            return text.isEmpty ? nil : text
        } catch {
            await ScreenAccess.note(error)
            return nil
        }
    }

    /// The longest side of the picture: enough for a full-screen window, without megapixels nobody reads.
    private static let maxSide = 3_000

    /// The app's window the field is in, else its largest.
    private static func window(of pid: pid_t, around field: CGRect?, in windows: [SCWindow]) -> SCWindow? {
        let own = windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 200 }
        if let field, let center = flipped(field).map({ CGPoint(x: $0.midX, y: $0.midY) }),
           let around = own.first(where: { $0.frame.contains(center) }) { return around }
        return own.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// `field` as a part of `window` (0…1, y down from the top).
    private static func part(of window: CGRect, field: CGRect) -> CGRect? {
        guard window.width > 0, window.height > 0, let frame = flipped(field) else { return nil }
        return CGRect(x: (frame.minX - window.minX) / window.width, y: (frame.minY - window.minY) / window.height,
                      width: frame.width / window.width, height: frame.height / window.height)
    }

    /// From AppKit's screen coordinates to the ones windows are given in (origin top left of the main display).
    private static func flipped(_ rect: CGRect) -> CGRect? {
        guard let height = NSScreen.screens.first?.frame.height else { return nil }
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
