import Foundation

// `render_page` with `path`: an HTML file in the session's working directory instead of inline `html`. The file and the
// images, stylesheets, scripts and fonts it refers to by a relative or absolute path are read once and embedded (CSS and
// scripts inline, the rest as data: URLs), so the page keeps working after the files change or move, and the sandbox
// stays as it is: no network, no file access from the page. Every file is resolved through its symlinks and must lie
// inside the working directory; what does not, or is missing or too large, is left out and named in the reply.
// Foundation only, so the rules are tested here (`RenderedPageTests`).

enum RenderedPageFile {
    /// The largest one embedded file may be.
    static let maxAssetBytes = 2 * 1024 * 1024
    /// The largest the page may grow with everything embedded.
    static let maxPageBytes = 6 * 1024 * 1024

    struct Loaded: Equatable {
        var html: String
        /// The references that were not embedded, each with why ("logo.png (outside the working directory)").
        var leftOut: [String]
        /// The file's name, the page's title when the agent gave none.
        var name: String
    }

    /// Reads the page at `path` (relative to `workdir`, or absolute inside it) with what it refers to embedded.
    static func load(_ path: String, workdir: String) -> Result<Loaded, BridgeArgumentError> {
        guard let root = realPath(workdir) else {
            return .failure(BridgeArgumentError("The session's working directory could not be read."))
        }
        let expanded = path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        guard let file = realPath(expanded) else {
            return .failure(BridgeArgumentError("No file at \(path)."))
        }
        guard isInside(file, root: root) else {
            return .failure(BridgeArgumentError("path must be a file inside the session's working directory."))
        }
        let ext = (file as NSString).pathExtension.lowercased()
        guard ext == "html" || ext == "htm" else {
            return .failure(BridgeArgumentError("path must be an .html file."))
        }
        guard let size = fileSize(file) else { return .failure(BridgeArgumentError("No file at \(path).")) }
        guard size <= RenderedPage.maxHTMLBytes else {
            return .failure(BridgeArgumentError("The page is too large (at most \(RenderedPage.maxHTMLBytes / 1024) KB)."))
        }
        guard let data = FileManager.default.contents(atPath: file), let html = String(data: data, encoding: .utf8) else {
            return .failure(BridgeArgumentError("The page could not be read as UTF-8 text."))
        }
        var embedder = Embedder(root: root)
        let page = embedder.embed(html, base: (file as NSString).deletingLastPathComponent)
        guard page.utf8.count <= maxPageBytes else {
            return .failure(BridgeArgumentError("With its files embedded the page is too large (at most \(maxPageBytes / 1024 / 1024) MB). Use smaller images."))
        }
        return .success(Loaded(html: page, leftOut: embedder.leftOut, name: (file as NSString).lastPathComponent))
    }

    /// Whether `path` (already resolved) is `root` or lies under it.
    static func isInside(_ path: String, root: String) -> Bool {
        let folder = root.hasSuffix("/") ? root : root + "/"
        return path == root || path.hasPrefix(folder)
    }

    /// The path with every symlink resolved, nil when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func fileSize(_ path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// The MIME type of a file embedded as a data: URL; nil for a kind that is not embedded.
    static func mimeType(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        default: return nil
        }
    }

    /// A reference to a local file: no scheme ("https:", "data:"), not protocol-relative, not a fragment.
    static func isLocalReference(_ reference: String) -> Bool {
        let value = reference.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !value.hasPrefix("#"), !value.hasPrefix("//") else { return false }
        return value.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:", options: .regularExpression) == nil
    }

    struct Embedder {
        let root: String
        var leftOut: [String] = []
        private var budget = RenderedPageFile.maxPageBytes
        private var depth = 0

        init(root: String) { self.root = root }

        /// The page with its stylesheets and scripts inlined and its images, media and fonts as data: URLs.
        mutating func embed(_ html: String, base: String) -> String {
            var page = html
            page = Self.replace(#"<link\b[^>]*>"#, in: page) { tag in
                guard tag.range(of: #"rel\s*=\s*["']?[^"'>]*stylesheet"#, options: [.regularExpression, .caseInsensitive]) != nil,
                      let href = Self.attribute("href", in: tag), isLocalReference(href) else { return nil }
                guard let css = text(href, base: base) else { return "" }
                return "<style>\n" + embedCSS(css.text, base: css.folder).replacingOccurrences(of: "</style", with: "<\\/style") + "\n</style>"
            }
            page = Self.replace(#"<script\b[^>]*\bsrc\s*=[^>]*>\s*</script\s*>"#, in: page) { tag in
                guard let src = Self.attribute("src", in: tag), isLocalReference(src) else { return nil }
                guard let script = text(src, base: base) else { return "" }
                let open = tag.replacingOccurrences(of: #"\s+src\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, with: "", options: [.regularExpression, .caseInsensitive])
                let head = open.range(of: ">").map { String(open[..<$0.upperBound]) } ?? "<script>"
                return head + script.text.replacingOccurrences(of: "</script", with: "<\\/script") + "</script>"
            }
            // What is left is only looked at outside scripts: a script's own strings stay as the agent wrote them.
            var pieces: [String] = []
            var last = page.startIndex
            for range in Self.scriptRanges(page) {
                pieces.append(embedMarkup(String(page[last..<range.lowerBound]), base: base))
                pieces.append(String(page[range]))
                last = range.upperBound
            }
            pieces.append(embedMarkup(String(page[last...]), base: base))
            page = pieces.joined()
            return page
        }

        /// Style blocks, style attributes and the `src`, `poster` and image `href` attributes of markup without scripts.
        private mutating func embedMarkup(_ markup: String, base: String) -> String {
            var text = Self.replace(#"<style\b[^>]*>[\s\S]*?</style\s*>"#, in: markup) { block in
                embedCSS(block, base: base)
            }
            text = Self.replace(#"\b(src|poster|href)(\s*=\s*)("[^"]*"|'[^']*')"#, in: text) { match in
                guard let equals = match.firstIndex(of: "=") else { return nil }
                let name = match[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let quoted = match[match.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                let value = Self.decodeEntities(String(quoted.dropFirst().dropLast()))
                // Only images, media and fonts are embedded: a link to another page or a frame stays as it is (and goes
                // nowhere in the sandbox).
                guard isLocalReference(value), mimeType(Self.strip(value)) != nil else { return nil }
                return name + "=\"" + (dataURL(value, base: base) ?? "") + "\""
            }
            return Self.replace(#"\bstyle\s*=\s*("[^"]*"|'[^']*')"#, in: text) { attribute in
                embedCSS(attribute, base: base)
            }
        }

        /// Where the page's `<script>…</script>` elements are.
        static func scriptRanges(_ page: String) -> [Range<String.Index>] {
            guard let regex = try? NSRegularExpression(pattern: #"<script\b[\s\S]*?</script\s*>"#, options: [.caseInsensitive]) else { return [] }
            return regex.matches(in: page, range: NSRange(page.startIndex..., in: page)).compactMap { Range($0.range, in: page) }
        }

        /// `url(...)` in CSS as data: URLs; `@import` of a local stylesheet inlined.
        mutating func embedCSS(_ css: String, base: String) -> String {
            var text = Self.replace(#"@import\s+(url\()?\s*["']([^"']+)["']\s*\)?\s*;"#, in: css) { rule in
                guard let start = rule.firstIndex(where: { $0 == "\"" || $0 == "'" }),
                      let end = rule[rule.index(after: start)...].firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
                let reference = String(rule[rule.index(after: start)..<end])
                guard isLocalReference(reference) else { return nil }
                // A stylesheet that imports itself, or a long chain of them, stops here.
                guard depth < 4 else { leftOut.append("\(Self.strip(reference)) (imported too deep)"); return "" }
                guard let imported = self.text(reference, base: base) else { return "" }
                depth += 1
                defer { depth -= 1 }
                return embedCSS(imported.text, base: imported.folder)
            }
            text = Self.replace(#"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s]+))\s*\)"#, in: text) { match in
                let inner = match.dropFirst(4).dropLast().trimmingCharacters(in: .whitespaces)
                let reference = inner.hasPrefix("\"") || inner.hasPrefix("'") ? String(inner.dropFirst().dropLast()) : inner
                guard isLocalReference(reference), mimeType(Self.strip(reference)) != nil else { return nil }
                return "url(\"" + (dataURL(Self.decodeEntities(reference), base: base) ?? "") + "\")"
            }
            return text
        }

        /// The file a reference names, resolved from `base`, when it lies inside the working directory and fits.
        private mutating func read(_ reference: String, base: String) -> (data: Data, path: String)? {
            let clean = Self.strip(reference)
            let decoded = clean.removingPercentEncoding ?? clean
            let joined = decoded.hasPrefix("/") ? decoded : (base as NSString).appendingPathComponent(decoded)
            guard let path = realPath(joined) else { leftOut.append("\(clean) (not found)"); return nil }
            guard isInside(path, root: root) else { leftOut.append("\(clean) (outside the working directory)"); return nil }
            guard let size = RenderedPageFile.fileSize(path) else { leftOut.append("\(clean) (not a file)"); return nil }
            guard size <= maxAssetBytes, size <= budget else { leftOut.append("\(clean) (too large)"); return nil }
            guard let data = FileManager.default.contents(atPath: path) else { leftOut.append("\(clean) (unreadable)"); return nil }
            budget -= data.count
            return (data, path)
        }

        private mutating func text(_ reference: String, base: String) -> (text: String, folder: String)? {
            guard let file = read(reference, base: base) else { return nil }
            guard let text = String(data: file.data, encoding: .utf8) else {
                leftOut.append("\(Self.strip(reference)) (not UTF-8 text)")
                return nil
            }
            return (text, (file.path as NSString).deletingLastPathComponent)
        }

        private mutating func dataURL(_ reference: String, base: String) -> String? {
            guard let mime = mimeType(Self.strip(reference)) else { return nil }
            guard let file = read(reference, base: base) else { return nil }
            return "data:\(mime);base64," + file.data.base64EncodedString()
        }

        /// Replaces every match of `pattern` with what `transform` makes of it; nil keeps the match as it is.
        private static func replace(_ pattern: String, in text: String, _ transform: (String) -> String?) -> String {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
            let source = text as NSString
            var result = ""
            var last = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: last, length: match.range.location - last))
                let found = source.substring(with: match.range)
                result += transform(found) ?? found
                last = match.range.location + match.range.length
            }
            result += source.substring(from: last)
            return result
        }

        static func attribute(_ name: String, in tag: String) -> String? {
            let pattern = #"\b"# + name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
            for group in 2...4 {
                if let range = Range(match.range(at: group), in: tag) { return decodeEntities(String(tag[range])) }
            }
            return nil
        }

        /// The path part of a reference, without its query or fragment.
        static func strip(_ reference: String) -> String {
            let value = reference.trimmingCharacters(in: .whitespaces)
            return String(value.prefix { $0 != "?" && $0 != "#" })
        }

        static func decodeEntities(_ value: String) -> String {
            value.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
        }
    }
}
