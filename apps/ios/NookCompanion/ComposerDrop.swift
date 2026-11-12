import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Dragging into a composer (docs/COMPANION.md › iPad): pictures, a file, links and text from another app (Split View,
// Slide Over, Stage Manager) or from another place in this one. Pictures go with the message as from the photo picker
// (`CompanionImageEncoder`), a small file as an attachment as from the share sheet (`CompanionFile`), links and text into
// the words. Nothing is sent by dropping: it all waits in the composer to read first.

extension View {
    /// Takes drops for a composer. `images` and `files` are left out where that composer cannot send them (Nook's chat
    /// takes words only; a Mac without `CompanionFeature.images` or `.attachments`). `enabled`: the composer is there.
    func composerDrop(text: Binding<String>, images: Binding<[CompanionImage]>? = nil, files: Binding<[CompanionFile]>? = nil,
                      enabled: Bool = true) -> some View {
        modifier(ComposerDrop(text: text, images: images, files: files, enabled: enabled))
    }
}

private struct ComposerDrop: ViewModifier {
    @EnvironmentObject private var client: CompanionClient
    @Binding var text: String
    let images: Binding<[CompanionImage]>?
    let files: Binding<[CompanionFile]>?
    let enabled: Bool
    @State private var targeted = false

    private var types: [UTType] {
        var types: [UTType] = [.url, .plainText]
        if images != nil { types.append(.image) }
        if files != nil { types += [.fileURL, .data] }
        return types
    }

    func body(content: Content) -> some View {
        content
            .onDrop(of: types, delegate: Delegate(enabled: enabled, types: types, targeted: $targeted, receive: receive))
            .overlay {
                if targeted {
                    ZStack {
                        Theme.shape(Theme.Radius.panel).fill(Theme.iris.opacity(0.06))
                        Theme.shape(Theme.Radius.panel).strokeBorder(Theme.iris.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        Label("Drop to add to your message", systemImage: "plus.circle")
                            .font(Theme.TextStyle.label).foregroundStyle(Theme.paper)
                            .padding(.horizontal, Theme.Spacing.lg).padding(.vertical, Theme.Spacing.md)
                            .roundedBackground(Theme.surface, radius: Theme.Radius.control)
                    }
                    .padding(Theme.Spacing.md)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .animation(Theme.hover, value: targeted)
    }

    private func receive(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            let dropped = await DroppedItems.load(providers, takesImages: images != nil, takesFiles: files != nil)
            var problems = dropped.problems
            if !dropped.text.isEmpty { text = DroppedText.merge(current: text, dropped: dropped.text) }
            if let images, !dropped.images.isEmpty {
                let room = CompanionImage.maxCount - images.wrappedValue.count
                if dropped.images.count > room { problems.append(String(localized: "Only \(CompanionImage.maxCount) pictures go with a message.")) }
                withAnimation(Theme.reveal) { images.wrappedValue += dropped.images.prefix(max(0, room)) }
            }
            if let files, !dropped.files.isEmpty {
                var kept = files.wrappedValue
                for file in dropped.files {
                    if kept.count >= CompanionFile.maxCount {
                        problems.append(String(localized: "Only one file goes with a message."))
                        break
                    }
                    if CompanionFile.fits(images: images?.wrappedValue ?? [], files: kept + [file]) {
                        kept.append(file)
                    } else {
                        problems.append(String(localized: "\(file.name) is too big to send from here (at most 150 KB). Share it on your Mac instead."))
                    }
                }
                withAnimation(Theme.reveal) { files.wrappedValue = kept }
            }
            if problems.isEmpty { Haptics.tap() } else {
                Haptics.warning()
                client.notice = Array(NSOrderedSet(array: problems)).compactMap { $0 as? String }.joined(separator: "\n")
            }
        }
    }

    private struct Delegate: DropDelegate {
        let enabled: Bool
        let types: [UTType]
        @Binding var targeted: Bool
        let receive: ([NSItemProvider]) -> Void

        func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: types) }
        func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
        func dropExited(info: DropInfo) { targeted = false }
        func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

        func performDrop(info: DropInfo) -> Bool {
            targeted = false
            guard enabled else { return false }
            receive(info.itemProviders(for: types))
            return true
        }
    }
}

/// What came out of the dropped items: words, pictures and files, and what could not be read.
enum DroppedItems {
    struct Loaded {
        var text = ""
        var images: [CompanionImage] = []
        var files: [CompanionFile] = []
        var problems: [String] = []
    }

    /// A picture first; then a web link; then a file (a file URL, or an item with a file name such as one from Files);
    /// then plain text.
    static func load(_ providers: [NSItemProvider], takesImages: Bool, takesFiles: Bool) async -> Loaded {
        var loaded = Loaded()
        var words: [String] = []
        for provider in providers {
            if takesImages, provider.canLoadObject(ofClass: UIImage.self) {
                if let image = await image(provider), let encoded = CompanionImageEncoder.encode(image) {
                    loaded.images.append(encoded)
                } else {
                    loaded.problems.append(String(localized: "A picture could not be read."))
                }
            } else if let url = await webLink(provider) {
                words.append(url.absoluteString)
            } else if isFile(provider) {
                guard takesFiles else {
                    loaded.problems.append(String(localized: "Files cannot go with this message."))
                    continue
                }
                switch await file(provider) {
                case .success(let file): loaded.files.append(file)
                case .failure(let problem): loaded.problems.append(problem.message)
                }
            } else if let string = await plainText(provider), !string.isEmpty {
                words.append(DroppedText.clip(string))
            }
        }
        loaded.text = words.joined(separator: "\n")
        return loaded
    }

    private static func image(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, _ in continuation.resume(returning: object as? UIImage) }
        }
    }

    private static func webLink(_ provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
              !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
              provider.canLoadObject(ofClass: URL.self) else { return nil }
        let url: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { object, _ in continuation.resume(returning: object) }
        }
        guard let url, !url.isFileURL else { return nil }
        return url
    }

    private static func plainText(_ provider: NSItemProvider) async -> String? {
        guard provider.canLoadObject(ofClass: String.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { object, _ in continuation.resume(returning: object) }
        }
    }

    /// A file, not a piece of text: a file URL, or an item named with an extension (a document dragged from Files).
    private static func isFile(_ provider: NSItemProvider) -> Bool {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return true }
        guard let name = provider.suggestedName, !(name as NSString).pathExtension.isEmpty else { return false }
        return provider.hasItemConformingToTypeIdentifier(UTType.data.identifier)
    }

    struct Problem: Error { let message: String }

    /// The file's bytes, read while the system holds its copy for us; at most `CompanionFile.maxBytes`.
    private static func file(_ provider: NSItemProvider) async -> Result<CompanionFile, Problem> {
        let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true } ?? UTType.data.identifier
        let suggested = provider.suggestedName
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type) { url, _ in
                guard let url else {
                    return continuation.resume(returning: .failure(Problem(message: String(localized: "The file could not be read."))))
                }
                let name = CompanionFile.safeName(suggested.map { name in
                    (name as NSString).pathExtension.isEmpty ? name + "." + url.pathExtension : name
                } ?? url.lastPathComponent) ?? "file"
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard size <= CompanionFile.maxBytes, let data = try? Data(contentsOf: url), data.count <= CompanionFile.maxBytes else {
                    return continuation.resume(returning: .failure(Problem(
                        message: String(localized: "\(name) is too big to send from here (at most 150 KB). Share it on your Mac instead."))))
                }
                guard !data.isEmpty else {
                    return continuation.resume(returning: .failure(Problem(message: String(localized: "The file could not be read."))))
                }
                continuation.resume(returning: .success(CompanionFile(name: name, bytes: data)))
            }
        }
    }
}

/// The file that goes with the next message, beside the pictures above the composer: its name, with a button to take
/// it off.
struct FileTray: View {
    @Binding var files: [CompanionFile]

    var body: some View {
        if !files.isEmpty {
            HStack(spacing: Theme.Spacing.md) {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(icon: SessionFilesView.symbol(file.name)).foregroundStyle(Theme.textSecondary)
                        Text(file.name).font(Theme.TextStyle.label).foregroundStyle(Theme.paper).lineLimit(1).truncationMode(.middle)
                        Button {
                            withAnimation(Theme.reveal) { _ = files.remove(at: index) }
                        } label: {
                            Image(icon: "xmark").font(Theme.font(9, .bold)).foregroundStyle(Theme.textSecondary)
                                .frame(width: 20, height: 20)
                                .background(Theme.smoke, in: Circle())
                        }
                        .buttonStyle(PressFade())
                        .accessibilityLabel("Remove file")
                    }
                    .padding(.leading, Theme.Spacing.md).padding(.trailing, Theme.Spacing.xs).padding(.vertical, Theme.Spacing.xs)
                    .roundedBackground(Theme.field, radius: Theme.Radius.control)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }
}
