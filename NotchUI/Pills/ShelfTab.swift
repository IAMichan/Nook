import SwiftUI
import UniformTypeIdentifiers

/// Shelf: sleep bestanden hierheen om ze even te bewaren. Klik op een bestand om Nook er iets over te vragen.
/// Nu nog alleen in het geheugen.
struct ShelfTab: View {
    @EnvironmentObject private var app: AppModel
    @State private var files: [URL] = []
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(files, id: \.self) { url in
                ShelfItem(url: url) { app.askAbout(url) }
                    .contextMenu {
                        Button("Vraag Nook erover") { app.askAbout(url) }
                        Button("Verstuur per mail…") { app.mailFile(url) }
                        Button("Toon in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Divider()
                        Button("Haal van de Shelf") { files.removeAll { $0 == url } }
                    }
            }

            dropZone
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async {
                        if !files.contains(url) { files.append(url) }
                    }
                }
            }
            return true
        }
    }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Text("Sleep bestanden hierheen")
                .font(NookTheme.font(12.5, .medium))
                .foregroundStyle(NookTheme.paper)
            Text("klik om te vragen, rechtsklik om te mailen")
                .font(NookTheme.font(12.5))
                .foregroundStyle(NookTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    targeted ? NookTheme.iris : NookTheme.line2,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
    }
}

private struct ShelfItem: View {
    let url: URL
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 36, height: 36)
                Text(url.lastPathComponent)
                    .font(NookTheme.font(12))
                    .foregroundStyle(NookTheme.paper)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 8)
            .frame(width: 108, height: 104)
            .background(RoundedRectangle(cornerRadius: 14).fill(hovering ? NookTheme.smoke : NookTheme.field))
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NookTheme.iris)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Vraag Nook over \(url.lastPathComponent)")
    }
}
