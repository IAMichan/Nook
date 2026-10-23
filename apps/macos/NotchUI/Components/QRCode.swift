import AppKit
import SwiftUI
import CoreImage.CIFilterBuiltins

/// A QR code of a text as a crisp image, for the screens that ask a phone to scan something (pairing the companion,
/// linking a chat app). Draw it with `.interpolation(.none)` on a light background.
enum QRCode {
    static func image(_ text: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A QR code for a phone to scan, the same everywhere (linking a chat app, WhatsApp, pairing the companion): crisp
/// pixels on a light card, so a phone camera reads it in a dark theme too.
struct QRCodeView: View {
    let image: NSImage
    var side: CGFloat = 200
    let label: String

    /// The code of a text, or nothing when it cannot be made.
    init?(text: String, side: CGFloat = 200, label: String) {
        guard let image = QRCode.image(text) else { return nil }
        self.init(image: image, side: side, label: label)
    }

    init(image: NSImage, side: CGFloat = 200, label: String) {
        self.image = image
        self.side = side
        self.label = label
    }

    var body: some View {
        Image(nsImage: image)
            .interpolation(.none)
            .resizable()
            .frame(width: side, height: side)
            .padding(NookTheme.Spacing.md)
            .background(RoundedRectangle(cornerRadius: NookTheme.Radius.card, style: .continuous).fill(NookTheme.paper))
            .accessibilityLabel(label)
    }
}
