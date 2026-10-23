import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Makes a file fit what WhatsApp takes before it goes, as WhatsApp's own apps do: a photo as JPEG (an iPhone's HEIC is
/// not taken), a video as MP4, a GIF as the short looping MP4 WhatsApp itself sends for one, a sticker as PNG when it is
/// no PNG, JPEG, WebP or GIF yet. Telegram and Nook's chat helper take files as they are. Converted files and pasted pictures land in
/// Nook's temporary folder, never next to the original.
enum ChatSendPrep {
    /// Where files made for sending go: one folder each, under the Mac's temporary folder.
    static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Nook Sending", isDirectory: true)
    }

    /// A new, empty place for a file called `name`.
    static func destination(name: String) throws -> URL {
        let dir = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
        return dir.appendingPathComponent(safe.isEmpty ? "file" : String(safe.suffix(120)))
    }

    /// The file as WhatsApp takes it; the same file when it already fits. Throws with a sentence you can act on.
    static func forWhatsApp(_ file: ChatAttachment) async throws -> ChatAttachment {
        let ext = file.fileExtension
        do {
            switch file.kind {
            case .photo where !["image/jpeg", "image/png"].contains(file.mimeType):
                return try picture(file, as: .jpeg, ext: "jpg", side: 2560)
            case .sticker where !["image/jpeg", "image/png", "image/webp", "image/gif"].contains(file.mimeType):
                return try picture(file, as: .png, ext: "png", side: 512)
            case .gif where ext == "gif":
                return try await gifVideo(file)
            case .video, .gif:
                return file.mimeType == "video/mp4" ? file : try await mp4(file)
            default:
                return file
            }
        } catch let error as NookError {
            throw error
        } catch {
            throw NookError(tr("chat.compose.convertFailed", file.name))
        }
    }

    /// A picture written anew as JPEG or PNG, at most `side` pixels on its longest side, turned upright.
    private static func picture(_ file: ChatAttachment, as type: UTType, ext: String, side: Int) throws -> ChatAttachment {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw NookError(tr("chat.compose.convertFailed", file.name))
        }
        let out = try destination(name: renamed(file.name, ext: ext))
        guard let target = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else {
            throw NookError(tr("chat.compose.convertFailed", file.name))
        }
        CGImageDestinationAddImage(target, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw NookError(tr("chat.compose.convertFailed", file.name)) }
        return converted(file, to: out)
    }

    /// A video as MP4 (H.264, at most 720p), the format every WhatsApp gateway and phone takes.
    private static func mp4(_ file: ChatAttachment) async throws -> ChatAttachment {
        let asset = AVURLAsset(url: file.url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw NookError(tr("chat.compose.convertFailed", file.name))
        }
        let out = try destination(name: renamed(file.name, ext: "mp4"))
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: out, as: .mp4)
        return converted(file, to: out)
    }

    /// A GIF as WhatsApp sends one: a silent MP4 of its frames, each shown as long as the GIF says, that the chat loops.
    private static func gifVideo(_ file: ChatAttachment) async throws -> ChatAttachment {
        let out = try destination(name: renamed(file.name, ext: "mp4"))
        let source = file.url
        try await Task.detached(priority: .userInitiated) { try writeFrames(of: source, to: out) }.value
        return converted(file, to: out)
    }

    private static func writeFrames(of gif: URL, to out: URL) throws {
        let failure = NookError(tr("chat.compose.convertFailed", gif.lastPathComponent))
        guard let source = CGImageSourceCreateWithURL(gif as CFURL, nil) else { throw failure }
        let count = min(CGImageSourceGetCount(source), 600)
        guard count > 0, let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw failure }
        // H.264 wants even sides; a GIF bigger than 720 pixels is scaled down.
        let scale = min(1, 720 / CGFloat(max(first.width, first.height)))
        let width = max(2, Int(CGFloat(first.width) * scale) / 2 * 2)
        let height = max(2, Int(CGFloat(first.height) * scale) / 2 * 2)

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw failure }
        writer.add(input)
        guard writer.startWriting() else { throw failure }
        writer.startSession(atSourceTime: .zero)

        // A GIF shorter than a second plays a few times over, so the video is long enough to show as a GIF.
        var frames: [(image: CGImage, seconds: Double)] = []
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            frames.append((image, delay(source, index)))
        }
        let length = frames.reduce(0) { $0 + $1.seconds }
        let rounds = length > 0 ? max(1, min(10, Int((1 / length).rounded(.up)))) : 1
        var time = CMTime.zero
        for frame in Array(repeating: frames, count: rounds).joined() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw failure }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { throw failure }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            // A GIF's see-through parts show white, as on WhatsApp.
            context?.setFillColor(CGColor(gray: 1, alpha: 1))
            context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context?.interpolationQuality = .high
            context?.draw(frame.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: time) else { throw failure }
            time = CMTimeAdd(time, CMTime(seconds: frame.seconds, preferredTimescale: 600))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw failure }
    }

    /// How long a GIF shows frame `index`: as it says, with browsers' 0.1 s for a frame that says almost nothing.
    private static func delay(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let seconds = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return seconds < 0.011 ? 0.1 : seconds
    }

    private static func renamed(_ name: String, ext: String) -> String {
        let base = (name as NSString).deletingPathExtension
        return (base.isEmpty ? "file" : base) + "." + ext
    }

    /// The attachment for the converted file: the same kind and caption, the new file's name, type and size.
    private static func converted(_ file: ChatAttachment, to out: URL) -> ChatAttachment {
        var copy = ChatAttachment(url: out, as: file.kind, seconds: file.seconds) ?? file
        copy.id = file.id
        copy.caption = file.caption
        return copy
    }

    // MARK: Pasted and dropped pictures

    /// A picture from the pasteboard or a drop without a file of its own (a screenshot, a picture copied in a browser),
    /// saved as PNG so it can go as a photo.
    static func save(_ image: NSImage, name: String = "image.png") throws -> URL {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NookError(tr("chat.compose.convertFailed", name))
        }
        let out = try destination(name: name)
        try png.write(to: out, options: .atomic)
        return out
    }
}
