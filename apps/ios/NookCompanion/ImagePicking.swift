import SwiftUI
import PhotosUI
import UIKit

/// Pictures for the agent, picked from the library and made small enough to travel to the Mac in one message
/// (`CompanionImage.maxBytes`): the longest side at most 1600 pt, then less quality, then smaller, until it fits.
enum CompanionImageEncoder {
    static func encode(_ image: UIImage) -> CompanionImage? {
        var side: CGFloat = 1600
        while side >= 480 {
            let scaled = resized(image, longestSide: side)
            for quality in [0.72, 0.6, 0.48, 0.36] as [CGFloat] {
                if let data = scaled.jpegData(compressionQuality: quality), data.count <= CompanionImage.maxBytes {
                    return CompanionImage(jpeg: data.base64EncodedString())
                }
            }
            side *= 0.75
        }
        return nil
    }

    private static func resized(_ image: UIImage, longestSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > longestSide, longest > 0 else { return image }
        let scale = longestSide / longest
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    /// The picked items as pictures for the Mac; one that cannot be read or made small enough is left out.
    static func load(_ items: [PhotosPickerItem]) async -> [CompanionImage] {
        var images: [CompanionImage] = []
        for item in items.prefix(CompanionImage.maxCount) {
            guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data),
                  let encoded = encode(image) else { continue }
            images.append(encoded)
        }
        return images
    }
}

/// The pictures that go with the next message, in a tray above the composer: each with a button to take it off.
struct ImageTray: View {
    @Binding var images: [CompanionImage]

    var body: some View {
        if !images.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        ZStack(alignment: .topTrailing) {
                            if let data = Data(base64Encoded: image.jpeg), let picture = UIImage(data: data) {
                                Image(uiImage: picture)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                            }
                            Button {
                                withAnimation(Theme.reveal) { _ = images.remove(at: index) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(Theme.font(9, .bold))
                                    .foregroundStyle(Theme.text)
                                    .frame(width: 20, height: 20)
                                    .background(Theme.raised, in: Circle())
                            }
                            .offset(x: 6, y: -6)
                            .accessibilityLabel("Remove picture")
                        }
                    }
                }
                .padding(.top, Theme.Spacing.sm)
                .padding(.horizontal, Theme.Spacing.xs)
            }
        }
    }
}

/// The button that picks pictures for the agent (at most `CompanionImage.maxCount`), as a quiet round control.
struct AttachPictureButton: View {
    @Binding var images: [CompanionImage]
    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $picked, maxSelectionCount: max(1, CompanionImage.maxCount - images.count), matching: .images) {
            Image(systemName: "photo")
                .font(Theme.font(14, .semibold))
                .foregroundStyle(images.count >= CompanionImage.maxCount ? Theme.textTertiary : Theme.textSecondary)
                .frame(width: 34, height: 34)
                .background(Theme.raised, in: Circle())
        }
        .disabled(images.count >= CompanionImage.maxCount)
        .accessibilityLabel("Add a picture")
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let loaded = await CompanionImageEncoder.load(items)
                picked = []
                if loaded.count < items.count { Haptics.warning() }
                withAnimation(Theme.reveal) { images = Array((images + loaded).prefix(CompanionImage.maxCount)) }
            }
        }
    }
}
