import QuickLook
import SwiftUI
import UIKit

/// A file of a session's folder that is no text (a picture, a PDF, a film…), fetched from the Mac in pieces
/// (`CompanionOp.fileData`, at most `FileChunk.maxFileBytes`) and opened with Quick Look, which also shares it. A picture
/// shows right away; anything else opens in Quick Look once it is in.
struct FilePreviewPanel: View {
    @EnvironmentObject private var client: CompanionClient
    let sessionID: String
    let path: String
    /// The size the folder listed, when known: a file over the limit is not fetched at all.
    var size: Int?
    @State private var progress: Double = 0
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var previewing: URL?

    private var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    private var tooLarge: Bool { (size ?? 0) > FileChunk.maxFileBytes }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            if tooLarge {
                WSEmptyState(symbol: "doc", title: String(localized: "Too large to preview"),
                             message: String(localized: "Files up to \(Self.limit) open on the phone. Open this one on your Mac."))
            } else if let url {
                if let image {
                    Button { previewing = url } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    }
                    .buttonStyle(PressFade())
                    .accessibilityLabel(Text("Preview \(name)"))
                }
                HStack(spacing: Theme.Spacing.md) {
                    NookPrimaryButton(title: String(localized: "Preview")) { previewing = url }
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                        .font(Theme.TextStyle.label)
                }
            } else if failed {
                WSEmptyState(symbol: "exclamationmark.triangle", title: String(localized: "Could not load this file"),
                             message: String(localized: "Your Mac did not send it. Try again in a moment."),
                             action: (String(localized: "Try again"), { Task { await load() } }))
            } else {
                VStack(spacing: Theme.Spacing.sm) {
                    ProgressView(value: progress).tint(Theme.iris)
                    Text("Loading from your Mac…").font(Theme.TextStyle.label).foregroundStyle(Theme.textSecondary)
                }
                .padding(.top, Theme.Spacing.xxl)
            }
        }
        .frame(maxWidth: .infinity)
        .quickLookPreview($previewing)
        .task { if url == nil, !tooLarge { await load() } }
    }

    private static var limit: String {
        ByteCountFormatter.string(fromByteCount: Int64(FileChunk.maxFileBytes), countStyle: .file)
    }

    private func load() async {
        failed = false
        progress = 0
        guard let fetched = await client.fetchFile(sessionID, path: path, progress: { progress = $0 }) else {
            if !Task.isCancelled { failed = true }
            return
        }
        image = UIImage(contentsOfFile: fetched.path)
        url = fetched
        // Anything but a picture has nothing to show here: it opens in Quick Look at once.
        if image == nil { previewing = fetched }
    }
}
