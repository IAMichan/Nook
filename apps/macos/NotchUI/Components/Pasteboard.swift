import AppKit

/// The general pasteboard, for the copy buttons and menu items.
enum Pasteboard {
    /// Replaces what is on the pasteboard with `text`.
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Replaces what is on the pasteboard with the picture in the file at `url`, at its full size, as PNG and TIFF so
    /// it pastes into any app. `fallback` (the smaller picture a bubble shows) is used when the file can't be read.
    @discardableResult
    static func copyImage(_ url: URL?, fallback: NSImage? = nil) -> Bool {
        guard let image = url.flatMap(NSImage.init(contentsOf:)) ?? fallback,
              let tiff = image.tiffRepresentation else { return false }
        let item = NSPasteboardItem()
        if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
        }
        item.setData(tiff, forType: .tiff)
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([item])
    }
}
