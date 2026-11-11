import SwiftUI
import AppKit
import CryptoKit

// Blocks of an answer that are not text: a folded `<details>` passage and an image on a line of its own. Drawn by
// `MarkdownView` for every conversation (a session's transcript, Nook's own chat), so each surface gets them.

// MARK: Details

/// A `<details>` passage: a line with a chevron and its summary, the passage under it once opened. Folded at first, as a
/// browser shows it.
struct MarkdownDetailsBlock: View {
    let summary: String
    let text: String
    let size: CGFloat
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: NookTheme.Spacing.sm) {
            Button {
                withAnimation(NookTheme.swap) { open.toggle() }
            } label: {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: "chevron.right")
                        .font(NookTheme.font(10, .bold))
                        .foregroundStyle(NookTheme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(MarkdownBlock.inline(summary.isEmpty ? tr("markdown.details") : summary, size: size))
                        .font(NookTheme.font(size, .medium))
                        .foregroundStyle(hovering ? NookTheme.paper : NookTheme.textStrong)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, NookTheme.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityAddTraits(open ? .isSelected : [])
            if open, !text.isEmpty {
                // Type-erased: the passage is an answer of its own, drawn by the view that draws this block.
                AnyView(MarkdownView(text: text, size: size))
                    .padding(.leading, NookTheme.Spacing.xl)
                    .padding(.bottom, NookTheme.Spacing.sm)
            }
        }
        .overlay(alignment: .top) { NookDivider() }
        .overlay(alignment: .bottom) { NookDivider() }
    }
}

// MARK: Images

/// An image an answer shows on a line of its own: from the web, or a file on this Mac (relative to the session's folder).
/// It shows whole, a click opens it big; one that cannot be read leaves a chip with its alt text.
struct MarkdownImageBlock: View {
    @Environment(\.fileLinkBase) private var fileLinkBase
    let alt: String
    let source: String
    @State private var image: NSImage?
    @State private var file: URL?
    @State private var missing = false

    private var name: String {
        alt.isEmpty ? (source as NSString).lastPathComponent : alt
    }

    var body: some View {
        Group {
            if missing {
                HStack(spacing: NookTheme.Spacing.sm) {
                    Image(icon: "photo.badge.exclamationmark")
                        .foregroundStyle(NookTheme.textTertiary)
                    Text(name)
                        .font(NookTheme.TextStyle.detail)
                        .foregroundStyle(NookTheme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, NookTheme.Spacing.md)
                .padding(.vertical, NookTheme.Spacing.sm)
                .background(NookTheme.shape(NookTheme.Radius.chip).fill(NookTheme.smoke))
                .help(source)
            } else {
                ChatMessagePicture(image: image, missing: false, name: name) { file }
                    .help(alt.isEmpty ? source : alt)
            }
        }
        .task(id: source + (fileLinkBase ?? "")) {
            let loaded = await AnswerImages.load(source, base: fileLinkBase)
            file = loaded?.file
            image = loaded?.image
            missing = loaded == nil
        }
    }
}

/// Reads the images answers show: a file on this Mac as it is, a web image once into Nook's caches (so it opens big
/// from a file as every other picture does).
enum AnswerImages {
    /// Larger than this a web image is not fetched.
    static let byteLimit = 20 * 1024 * 1024

    static func load(_ source: String, base: String?) async -> (image: NSImage, file: URL)? {
        await Task.detached(priority: .utility) { () -> (image: NSImage, file: URL)? in
            guard let file = await localFile(source, base: base),
                  let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return nil }
            return (image, file)
        }.value
    }

    /// The file an image source stands for, fetched first when it is on the web.
    private static func localFile(_ source: String, base: String?) async -> URL? {
        let lower = source.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: source), MarkdownBlock.isSafeLink(url) else { return nil }
            return await fetched(url)
        }
        if lower.hasPrefix("file://") { return URL(string: source).flatMap { $0.isFileURL ? $0 : nil } }
        let path = (source.removingPercentEncoding ?? source) as NSString
        if path.hasPrefix("~") { return URL(fileURLWithPath: path.expandingTildeInPath) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path as String) }
        guard let base else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(path as String).standardizedFileURL
    }

    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nook/AnswerImages", isDirectory: true)
    }

    private static func fetched(_ url: URL) async -> URL? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty || url.pathExtension.count > 5 ? "img" : url.pathExtension
        let target = folder.appendingPathComponent(String(digest.prefix(32))).appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              data.count <= byteLimit, NSImage(data: data) != nil else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        return target
    }
}

// MARK: Tables

/// A table of an answer written out again: as Markdown, or as CSV for a spreadsheet.
enum TableText {
    static func markdown(header: [String], rows: [[String]]) -> String {
        func line(_ cells: [String]) -> String {
            "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }
        return ([line(header), line(header.map { _ in "---" })] + rows.map(line)).joined(separator: "\n")
    }

    /// Cells without their Markdown markers, quoted where a comma, quote or line break needs it.
    static func csv(header: [String], rows: [[String]]) -> String {
        func cell(_ text: String) -> String {
            let plain = ChoiceList.plain(text)
            guard plain.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return plain }
            return "\"" + plain.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return ([header] + rows).map { $0.map(cell).joined(separator: ",") }.joined(separator: "\n")
    }
}

/// The copy button under a table: as Markdown or as CSV.
struct TableCopyMenu: View {
    let header: [String]
    let rows: [[String]]
    @State private var copied = false

    var body: some View {
        Menu {
            Button(tr("table.copyMarkdown")) { copy(TableText.markdown(header: header, rows: rows)) }
            Button(tr("table.copyCSV")) { copy(TableText.csv(header: header, rows: rows)) }
        } label: {
            Image(icon: copied ? "checkmark" : "doc.on.doc")
                .font(NookTheme.font(11, .medium))
                .foregroundStyle(NookTheme.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(copied ? tr("button.copied") : tr("table.copy"))
        .accessibilityLabel(tr("table.copy"))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}
