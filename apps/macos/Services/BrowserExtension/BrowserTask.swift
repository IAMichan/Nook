import Foundation

/// A task the user gives Nook in the browser's side panel ("fill in this form", "find a flight and pick the cheapest"):
/// the brain works through it live in that browser, as in Claude in Chrome. Each `chrome_*` step runs at once and its
/// result (what the page shows now, with refs) comes back before the next step is chosen, instead of the whole thing
/// becoming a plan the user runs on the Mac without Nook seeing what each click did.
///
/// Nook still decides nothing on its own: every step goes to the extension with `ask`, and the side panel asks the
/// user first unless they let Nook act on that site without asking. A step that pays, sends, deletes, books or signs
/// always asks, also on such a site (`pointOfNoReturn` in apps/browser-extension/lib/core.js). See
/// docs/BROWSER-EXTENSION.md. Foundation only, so the core tests check it on Linux.
final class BrowserTask: @unchecked Sendable {
    typealias Step = @MainActor (_ tool: String, _ input: [String: Any]) async -> (output: String, isError: Bool)

    /// Runs one step in the browser (the asker's own `perform`).
    let step: Step

    init(step: @escaping Step) {
        self.step = step
    }

    /// The first version of the extension that asks in its side panel before a step (`ask` on a command). An older one
    /// would run the step without asking, so its side panel's questions go the old way: actions become a plan the user
    /// runs on the Mac.
    static let firstVersion = [1, 4, 0]

    /// Whether the extension that says `version` in its hello asks before a step.
    static func supported(extensionVersion version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        for (index, wanted) in firstVersion.enumerated() {
            let have = index < parts.count ? parts[index] : 0
            if have != wanted { return have > wanted }
        }
        return true
    }

    /// The tools whose steps run live in the browser: all of `chrome_*` that act. The other actions of an answer (a mail,
    /// an event) are still proposed as usual.
    static func isLive(_ tool: String) -> Bool {
        BrowserExtensionTools.definition(tool)?.isAction ?? false
    }

    /// Reads whose answer changes by itself while a task runs (a page that loads): read again on every call.
    static let liveReads: Set<String> = Set(BrowserExtensionTools.all.filter { !$0.isAction }.map(\.name))

    /// A task in the browser takes many small steps: more rounds and calls than an answer.
    static let rounds = 40
    static let calls = 80

    /// What the brain is told about working this way, with the request.
    static let instruction = """
    The user asked from Nook's side panel in their own browser. Work on the page yourself, step by step, with the chrome_* \
    tools: chrome_open, chrome_click, chrome_type, chrome_key and chrome_scroll run right away, one at a time, and each \
    result already says what the page shows now and what can be used in view (with refs), so take the next step from it \
    without calling chrome_find again. Keep going until the task is done, then say in one or two sentences what you did. \
    Nook asks the user itself before a step when that is needed (the side panel shows it), so never ask for permission in \
    your text and never stop to propose steps. When a step is refused, do not try it another way: say what is left. \
    Prefer refs over selectors, type a whole value at once, and use submit: true on chrome_type instead of a separate \
    click when a field's form should be sent.
    """

    /// The line the extension's approval card shows for a step, and whether Nook itself already knows it cannot be
    /// undone (typing that submits a form). The extension adds what it sees on the page (the button's own words).
    static func ask(_ definition: BrowserExtensionTools.Definition, _ input: [String: Any], summary: String) -> [String: Any] {
        let submits = definition.method == "type" && BridgeArgs.bool(input["submit"]) == true
        return ["summary": summary, "submits": submits]
    }
}
