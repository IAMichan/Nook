import AppKit
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
