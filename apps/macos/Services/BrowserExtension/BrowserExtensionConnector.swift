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

    /// One live step of a task from the side panel (`BrowserTask`): the side panel asks the user first unless they let
    /// Nook act on that site without asking. What the page shows after it comes back as the result.
    static func runLive(_ definition: BrowserExtensionTools.Definition, _ input: [String: Any], summary: String) async -> (output: String, isError: Bool) {
        do {
            return (try await run(definition, input, ask: BrowserTask.ask(definition, input, summary: summary)), false)
        } catch {
            return ("Error: \(error.localizedDescription)", true)
        }
    }

    /// A coding agent's step (`nook_use`): what happened when it was sent with `ask.trusted`.
    enum TrustedStep: Equatable {
        /// The site acts without asking and nothing about the step is final: it ran, with this result.
        case ran(String)
        case failed(String)
        /// It did not run: Nook's approval card asks, with "Always on <site>" unless the step is final.
        case needsApproval(BrowserExtensionApproval)
    }

    /// "Always on <site>" chosen in Nook's approval card for the step that runs now: the extension remembers the site.
    @TaskLocal static var trust: String?

    /// The coding agent whose step runs now (`driver(_:)`), so the page glows in its logo's colors; nil for Nook itself.
    @TaskLocal static var driver: Driver?

    struct Driver: Sendable, Equatable {
        let name: String
        let colors: [String]
        var payload: [String: Any] { ["name": name, "colors": colors] }
    }

    /// What the extension gets about the agent that drives the page: its name and the colors of its logo
    /// (`AgentLogo.colors`, as Nook's own browser glows in them), as `#RRGGBB` the way a dark surface shows them.
    static func driver(_ agent: String) -> Driver {
        let dark = NSAppearance(named: .darkAqua)
        let colors: [String] = AgentLogo.colors(of: agent).compactMap { color in
            var hex: String?
            let resolve = {
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                let channel = { (value: CGFloat) in UInt32((min(max(value, 0), 1) * 255).rounded()) }
                hex = NookColor.string(channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent))
            }
            if let dark { dark.performAsCurrentDrawingAppearance(resolve) } else { resolve() }
            return hex
        }
        return Driver(name: agent, colors: colors)
    }

    /// Sends a coding agent's step so that it runs at once on a site the user lets Nook act on without asking (the
    /// switch in the side panel, or "Always" on an earlier card), and comes back for Nook's own approval card
    /// otherwise. nil when this is no browser action or the browser's extension is too old to know `ask.trusted`: Nook
    /// asks as it always did.
    static func runIfTrusted(_ name: String, _ input: [String: Any], summary: String) async -> TrustedStep? {
        guard let definition = BrowserExtensionTools.definition(name), definition.isAction,
              let client = BrowserExtensionService.shared.hub.client(BridgeArgs.string(input["browser"])),
              BrowserTask.asksOnlyIfTrusted(extensionVersion: client.version) else { return nil }
        do {
            return .ran(try await run(definition, input, ask: BrowserTask.ask(definition, input, summary: summary, trusted: true)))
        } catch let waiting as WaitsForApproval {
            return .needsApproval(waiting.approval)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private struct WaitsForApproval: Error {
        let approval: BrowserExtensionApproval
    }

    private static func run(_ definition: BrowserExtensionTools.Definition, _ input: [String: Any], ask: [String: Any]? = nil) async throws -> String {
        let params: [String: Any]
        switch BrowserExtensionTools.params(for: definition, input) {
        case .success(let value): params = value
        case .failure(let error): throw NookError(error.message)
        }
        let browser = BridgeArgs.string(input["browser"])
        let outcome = await BrowserExtensionService.shared.hub.call(definition.method, params: params, browser: browser, timeout: definition.timeout,
                                                                     ask: ask, trust: ask == nil ? trust : nil, by: driver?.payload)
        if !outcome.ok, let approval = outcome.approval { throw WaitsForApproval(approval: approval) }
        guard outcome.ok else { throw NookError(outcome.error.isEmpty ? "The browser could not do that." : outcome.error) }
        switch definition.method {
        case "find":
            BrowserExtensionRefs.shared.learn(outcome.text, tab: params["tab"] as? Int)
            return outcome.text
        case "screenshot":
            return try saveScreenshot(outcome)
        case "click", "type", "key", "open", "scroll":
            // What the page shows after the step names its elements for the next step's approval line.
            if let now = outcome.text.range(of: "Now: ") {
                BrowserExtensionRefs.shared.learn(String(outcome.text[now.lowerBound...]), tab: params["tab"] as? Int, merge: true)
            }
            return outcome.text
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
