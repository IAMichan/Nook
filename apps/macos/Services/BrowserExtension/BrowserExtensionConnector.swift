import SwiftUI

/// The user's own browser, through Nook's extension, as a source: its `chrome_*` tools read tabs and pages and act on
/// them, for Nook Chat and (through `nook_tools`/`nook_use`) every coding agent. Only there while a browser with the
/// extension is connected. Reads run directly; actions wait for the user's approval and land in the audit log, as every
/// other action does. What pages say is untrusted text, never instructions.
@MainActor
final class BrowserExtensionConnector: ContextSource {
    let id = BrowserExtensionTools.sourceID
    var title: String { tr("browserExt.source.title") }
    let symbol = "puzzlepiece.extension"
    var accent: Color { NookTheme.blue }
    var iconDomain: String? { nil }
    private(set) var status = ConnectorStatus()

    private var service: BrowserExtensionService { .shared }

    init() {
        // The browsers by name, and what people call a page (as the Browser source does).
        SourceCatalog.register(SourceDescriptor(id: id, title: "Browser extension", kind: .builtIn), tools: BrowserExtensionTools.names,
                               aliases: [#"browser\w*"#, "tabs?", #"tabblad\w*"#, "chrome", "brave", "vivaldi", "chromium", "microsoft edge"],
                               intents: ["pagina", "page", "website", "site", "artikel", "article", "formulier", "form", "seite", "formular"])
    }

    var isActive: Bool { service.enabled && !service.connected.isEmpty }
    var refreshInterval: TimeInterval { 60 }

    func refresh() async {
        service.refresh()
        guard service.enabled else {
            status = ConnectorStatus(state: .off, detail: tr("browserExt.source.detail"))
            return
        }
        let browsers = service.connected.map { $0.browser.isEmpty ? tr("browserExt.source.unnamed") : $0.browser }
        status = browsers.isEmpty
            ? ConnectorStatus(state: .off, headline: tr("browserExt.source.waiting"), detail: tr("browserExt.source.detail"))
            : ConnectorStatus(state: .ok, headline: browsers.joined(separator: ", "), detail: tr("browserExt.source.detail"), updated: Date())
    }

    func contextLines() -> [String] {
        guard isActive else { return [] }
        let browsers = service.connected.map(\.browser).filter { !$0.isEmpty }
        return ["Nook's extension is connected in the user's own browser (\(browsers.isEmpty ? "a Chromium browser" : browsers.joined(separator: ", "))): chrome_tabs lists its tabs, chrome_read reads a page as the user sees it (signed in), chrome_find lists what can be clicked or filled in, and chrome_open, chrome_click, chrome_type and chrome_key act there after the user approves. Prefer these over read_browser_tab for that browser."]
    }

    var tools: [ToolSpec] {
        guard isActive else { return [] }
        return BrowserExtensionTools.all.map(spec)
    }

    private func spec(_ definition: BrowserExtensionTools.Definition) -> ToolSpec {
        ToolSpec(
            name: definition.name,
            description: definition.description,
            schema: definition.schema,
            kind: definition.isAction ? .action : .read,
            summarize: { input in BrowserExtensionTools.summary(definition, input) },
            tag: { _ in definition.isAction ? (tr("browserExt.tag"), StepTone.caution) : ("", StepTone.neutral) },
            run: { input in try await Self.run(definition, input) }
        )
    }

    private static func run(_ definition: BrowserExtensionTools.Definition, _ input: [String: Any]) async throws -> String {
        let params: [String: Any]
        switch BrowserExtensionTools.params(for: definition, input) {
        case .success(let value): params = value
        case .failure(let error): throw NookError(error.message)
        }
        let browser = BridgeArgs.string(input["browser"])
        let outcome = await BrowserExtensionService.shared.hub.call(definition.method, params: params, browser: browser, timeout: definition.timeout)
        guard outcome.ok else { throw NookError(outcome.error.isEmpty ? "The browser could not do that." : outcome.error) }
        switch definition.method {
        case "find":
            BrowserExtensionRefs.shared.learn(outcome.text, tab: params["tab"] as? Int)
            return outcome.text
        case "screenshot":
            return try saveScreenshot(outcome)
        default:
            return outcome.text
        }
    }

    /// Writes the screenshot to Nook's folder (the newest 20 are kept) and tells where it is.
    private static func saveScreenshot(_ outcome: BrowserExtensionOutcome) throws -> String {
        guard let comma = outcome.image.firstIndex(of: ","), let data = Data(base64Encoded: String(outcome.image[outcome.image.index(after: comma)...])) else {
            throw NookError("The browser sent no picture.")
        }
        let folder = NookPaths.supportDirectory.appendingPathComponent("Browser Screenshots", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent("screenshot-\(stamp).jpg")
        try data.write(to: file, options: .atomic)
        let old = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .dropFirst(20)
        old.forEach { try? fm.removeItem(at: $0) }
        return "\(outcome.text) Saved as \(file.path) (JPEG)."
    }
}
