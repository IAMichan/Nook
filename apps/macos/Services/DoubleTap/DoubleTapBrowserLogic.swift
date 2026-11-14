import Foundation

// Double Tap in a Chromium browser through Nook's browser extension (apps/browser-extension): the page agent reads the
// form in the tab in front in one call (`form`) and fills every field in one more (`fill`). That is faster and surer than
// walking the browser's accessibility tree, which Chromium builds only on request and which leaves out many labels. The
// extension's service worker keeps its port to Nook while the browser runs, with or without its side panel open, and it
// wakes and reconnects when you switch to the browser. Without the extension (or while it is paused, or the site is
// switched off there) Double Tap works through the accessibility layer as before. Foundation only: tested on Linux.

/// A form in a browser tab as the extension's `form` command read it.
struct DoubleTapPage: Equatable {
    struct Button: Equatable {
        var ref: String
        var label: String
    }

    var title = ""
    var url = ""
    /// The fields in reading order; `source` is the index into `refs`.
    var fields: [DoubleTapField] = []
    /// The page agent's ref of each field, by `DoubleTapField.source`.
    var refs: [String] = []
    /// The page's text around its fields in reading order (`DoubleTapLogic.formText`).
    var pieces: [DoubleTapFormPiece] = []
    var buttons: [Button] = []
    /// The button the page itself marks as the one that sends the form (`type=submit`).
    var preferred: Int?
    var selection = ""
    var focusIsSecure = false
    /// What has the keyboard on the page, as the suggestions need it.
    var focus: DoubleTapScene.Focus = .none
    var focusEmpty = true
    var placeholder = ""

    /// The button that sends this form, by the same rules as a form read through the accessibility layer.
    var submit: Button? {
        DoubleTapLogic.submitButton(labels: buttons.map(\.label), defaultIndex: preferred).map { buttons[$0] }
    }
}

extension DoubleTapLogic {
    /// How long Double Tap waits for the extension to read a form: past this the accessibility layer reads it instead.
    static let browserReadTimeout: TimeInterval = 4
    /// How long it waits for the extension to fill the fields.
    static let browserFillTimeout: TimeInterval = 8

    /// Whether the app in front is a Chromium browser, where Nook's extension can run.
    static func isChromium(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return AppCatalog.browsers.contains { $0.bundleID == bundleID && $0.engine == .chromium }
    }

    /// The connected browser that is the app in front (`appName` as macOS names it: "Google Chrome", "Brave Browser",
    /// "Arc"), by the name its extension said hello with. With one browser connected and no name to tell, that one.
    static func browserClient(appName: String, bundleID: String?, clients: [BrowserExtensionClient]) -> BrowserExtensionClient? {
        guard isChromium(bundleID: bundleID), !clients.isEmpty else { return nil }
        let app = browserFold(appName)
        if let exact = clients.first(where: { !$0.browser.isEmpty && browserFold($0.browser) == app }) { return exact }
        // "Brave" says hello for "Brave Browser"; "Google Chrome" for "Google Chrome Beta" never wins over an exact match.
        if let named = clients.first(where: { client in
            let name = browserFold(client.browser)
            return !name.isEmpty && name != "chromium" && (app.hasPrefix(name) || name.hasPrefix(app))
        }) { return named }
        // Arc and Vivaldi often say hello as Chrome: with only one browser connected, that one is the one in front.
        return clients.count == 1 ? clients.first : nil
    }

    private static func browserFold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    /// The page the extension's `form` command describes (its JSON text); nil when it is not one.
    static func page(fromJSON text: String) -> DoubleTapPage? {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawFields = object["fields"] as? [[String: Any]] else { return nil }
        var page = DoubleTapPage()
        page.title = object["title"] as? String ?? ""
        page.url = object["url"] as? String ?? ""
        page.selection = object["selection"] as? String ?? ""
        for raw in rawFields {
            guard let ref = raw["ref"] as? String, !ref.isEmpty else { continue }
            let role = raw["role"] as? String ?? "field"
            let secure = (raw["secure"] as? Bool ?? false) || role == "password"
            var label = (raw["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // A field named only by its autofill hint ("email", "postal-code") still tells the brain what it asks.
            if label.isEmpty, let hint = raw["autocomplete"] as? String, !hint.isEmpty, hint != "on", hint != "off" { label = hint }
            if let options = raw["options"] as? [String], !options.isEmpty {
                label += (label.isEmpty ? "" : " ") + "(options: " + options.prefix(20).joined(separator: ", ") + ")"
            }
            page.fields.append(DoubleTapField(id: page.fields.count + 1, role: role, label: label,
                                              value: secure ? "" : raw["value"] as? String ?? "",
                                              focused: raw["focused"] as? Bool ?? false, secure: secure,
                                              settable: raw["settable"] as? Bool ?? true, source: page.refs.count))
            page.refs.append(ref)
        }
        // The pieces name fields by their place in the page's list; a field skipped above is left out.
        let kept = Dictionary(uniqueKeysWithValues: rawFields.enumerated().compactMap { index, raw -> (Int, Int)? in
            guard let ref = raw["ref"] as? String, let at = page.refs.firstIndex(of: ref) else { return nil }
            return (index, at)
        })
        for raw in object["pieces"] as? [[String: Any]] ?? [] {
            if let text = raw["text"] as? String {
                page.pieces.append(.text(text))
            } else if let index = raw["field"] as? Int, let source = kept[index] {
                page.pieces.append(.field(source))
            }
        }
        page.buttons = (object["buttons"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let ref = raw["ref"] as? String, let label = raw["label"] as? String, !label.isEmpty else { return nil }
            return DoubleTapPage.Button(ref: ref, label: label)
        }
        if let preferred = object["preferred"] as? Int, page.buttons.indices.contains(preferred) { page.preferred = preferred }
        if let focus = object["focus"] as? [String: Any] {
            let role = focus["role"] as? String ?? ""
            page.focusIsSecure = focus["secure"] as? Bool ?? false
            page.focus = page.focusIsSecure ? .none : (role == "textarea" ? .text : .field)
            page.focusEmpty = focus["empty"] as? Bool ?? true
            page.placeholder = focus["placeholder"] as? String ?? ""
        }
        return page
    }

    /// The scene the Double Tap field's suggestions read, from a page the extension read.
    static func scene(of page: DoubleTapPage, app: String, bundleID: String) -> DoubleTapScene {
        var scene = DoubleTapScene()
        scene.app = app
        scene.bundleID = bundleID
        scene.viaExtension = true
        guard !page.focusIsSecure else { return scene }
        scene.focus = page.focus
        scene.focusEmpty = page.focusEmpty
        scene.placeholder = page.placeholder
        // The page's selection counts only where Nook can type over it.
        scene.selection = page.focus == .none ? "" : String(page.selection.prefix(4_000))
        if scene.selection.isEmpty {
            scene.emptyFields = candidates(page.fields).filter(\.isEmpty).count
        }
        return scene
    }

    /// The `fill` command's values: the ref of each field the brain answered for, with its value.
    static func fillValues(_ values: [Int: String], fields: [DoubleTapField], page: DoubleTapPage) -> [[String: String]] {
        fields.compactMap { field in
            guard let value = values[field.id], page.refs.indices.contains(field.source) else { return nil }
            return ["ref": page.refs[field.source], "value": value]
        }
    }

    /// A field's label as the card shows it: without the options a list offers, which only the brain needs.
    static func shownLabel(_ label: String) -> String {
        guard let range = label.range(of: " (options: ") ?? label.range(of: "(options: ") else { return label }
        return String(label[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Whether the extension refused because of the user's own brake there (Nook paused in that browser, or the site
    /// switched off in its side panel): then Double Tap leaves the page alone instead of filling it another way.
    static func extensionRefused(_ error: String) -> Bool {
        error.contains("paused Nook") || error.contains("switched Nook off")
    }

    /// The refs the extension wrote, from `fill`'s answer.
    static func written(fromFill text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        return object["written"] as? [String] ?? []
    }
}
