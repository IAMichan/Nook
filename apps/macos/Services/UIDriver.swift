import AppKit
import ApplicationServices

/// Nook's hands: reads an app's window through the accessibility layer and performs approved `UIControl` steps in it
/// with real clicks, key presses and scrolling. This is how Nook changes something in an app that has no tool or menu
/// command for it, such as a switch in System Settings.
///
/// Every step stays inside the one app the user approved: it is brought to the front first and must still be in front
/// when a key is pressed; a click on a point lands only when that app's own window is on top there; elements are looked
/// up in that app only. Nook never types into a password field and never drives apps that hold passwords or run
/// commands, nor itself (`UIControl.isBlocked`).
@MainActor
enum UIDriver {
    static let readTool = "read_ui"
    static let controlTool = "control_ui"
    static let lookTool = "look_ui"

    /// The last picture `look_ui` took, for a brain that can see: handed over with the tool's result (`takePicture`).
    private static var picture: ChatImage?

    /// The picture of the last `look_ui`, once; nil when there is none.
    static func takePicture() -> ChatImage? {
        defer { picture = nil }
        return picture
    }

    /// A pause after each step, so the app can draw what changed before the next step looks for it.
    private static let settle: UInt64 = 400_000_000

    /// Where Nook is about to act (screen point, top-left origin) and on what: draws Nook's own cursor there (`Takeover`).
    static var onAct: ((CGPoint, String) -> Void)?

    /// Browsers: text goes in with real key presses, so a web page sees typing as typing (its scripts may ignore a value
    /// that is only set).
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "org.mozilla.firefox", "ai.perplexity.comet", "com.openai.atlas"
    ]

    static var tools: [ToolSpec] {
        [
            ToolSpec(
                name: readTool,
                description: "Reads the buttons, switches, checkboxes, fields, menus and texts in the front window of a Mac app (locally, through the accessibility layer), with the label to name each one by and where it is on screen. Use it before control_ui, and again after control_ui ran, to see what changed. In a web page, links carry the text a person sees (a product's name, a title) and prices are listed as text; elements marked (off screen) are on the page but scrolled out of view: scroll to reach them before clicking. A dropdown that is open lists its options as menu items. When the app draws its own controls, it also lists the text it sees on screen with its position: click those with x and y. When it still shows too little, use look_ui. For System Settings: open the right pane with control_ui (action open with an x-apple.systempreferences: url) or by clicking it in the sidebar, then read again. For Focus (Do Not Disturb), Wi-Fi, Bluetooth, sound and display brightness: read \"Control Center\", click its menu bar item (Control Center, or Focus when it is in the menu bar), then read again to see the panel. App names work in any language: \"System Settings\" also finds \"Systeeminstellingen\".",
                schema: [
                    "type": "object",
                    "properties": ["app": ["type": "string", "description": "Name of the app, e.g. \"System Settings\", \"Control Center\" or \"Safari\". Without it: the app in front."]] as [String: Any],
                    "required": [String]()
                ],
                kind: .read,
                summarize: { input in tr("control.read.plan", (input["app"] as? String) ?? tr("control.frontApp")) },
                tag: { _ in ("", .neutral) },
                run: { input in
                    try checkAccess()
                    let app = try await target((input["app"] as? String) ?? "")
                    let window = await settledRead(app)
                    let elements = window.items.map(\.element)
                    var text = UIControl.describe(app: app.localizedName ?? "", window: window.title, elements: elements)
                    if UIControl.needsSeenText(elements) {
                        let seen = UIControl.describeSeen(await ScreenReader.seenLines(of: app))
                        if !seen.isEmpty { text += "\n\n" + seen }
                    }
                    return text
                }
            ),
            ToolSpec(
                name: lookTool,
                description: "Looks at the front window of a Mac app the way a person does: takes a fresh picture of it and lists every text seen on it with its screen position (x,y of its centre). Brains that can see also get the picture itself. Use it when read_ui shows little or nothing useful (apps that draw their own controls, canvases, games, remote screens, images, web apps), to find something by how it looks (an icon, a colour, a position), and to check the result of a step with your own eyes. In the picture, pixel (px, py) is screen point (window x + px, window y + py): click there with control_ui x and y.",
                schema: [
                    "type": "object",
                    "properties": ["app": ["type": "string", "description": "Name of the app. Without it: the app in front."]] as [String: Any],
                    "required": [String]()
                ],
                kind: .read,
                summarize: { input in tr("control.look.plan", (input["app"] as? String) ?? tr("control.frontApp")) },
                tag: { _ in ("", .neutral) },
                run: { input in
                    try checkAccess()
                    let app = try await target((input["app"] as? String) ?? "")
                    return await look(app)
                }
            ),
            ToolSpec(
                name: controlTool,
                description: "Uses the mouse and keyboard in one Mac app, the way the user would: click buttons, switches, checkboxes, sidebar rows and menu items, type in fields, press keys and shortcuts, scroll. Use it when the user asks to change a setting or do something in an app that no other tool or menu command (app_menu_command) can do, e.g. turn on Night Shift or change the appearance in System Settings, or turn on Do Not Disturb in Control Center (app \"Control Center\": System Settings has no switch that turns a Focus on now). Read the window with read_ui first and name elements by their exact label (add role or index when labels repeat; x and y only when an element has no label). Steps run in order after the user approved them; propose only the steps you can see or are sure will appear (a menu that opens after a click). After they ran, Nook reads the window again and you continue with the next steps until the goal is reached.",
                schema: controlSchema,
                kind: .action,
                summarize: { input in summary(app: (input["app"] as? String) ?? "", steps: UIControl.steps(input["steps"])) },
                tag: { _ in (tr("control.tag"), .caution) },
                run: { input in try await perform(app: (input["app"] as? String) ?? "", steps: UIControl.steps(input["steps"])) }
            )
        ]
    }

    private static var controlSchema: [String: Any] {
        let step: [String: Any] = [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": UIControl.Action.allCases.map(\.rawValue), "description": "click, double_click, right_click, type (into the focused field, or into element), key (a key or shortcut), scroll, open (the app, or a System Settings pane with url), wait, drag (press on element or x,y, move to to_element or to_x,to_y, release: move a file, a slider, a window, select text), hover (move the mouse over element or x,y without clicking, to show a tooltip or a menu that opens on hover)."] as [String: Any],
                "element": ["type": "string", "description": "Label of the element exactly as read_ui shows it."],
                "role": ["type": "string", "description": "Role from read_ui to tell same labels apart: button, checkbox, switch, radio, popup, field, row, menuitem, tab…"],
                "index": ["type": "integer", "description": "Which of several matching elements, counted from the top left; 1 is the first."],
                "x": ["type": "number", "description": "Screen x of a point to click (from read_ui), only when the element has no label."],
                "y": ["type": "number", "description": "Screen y of that point."],
                "text": ["type": "string", "description": "For type: the text."],
                "replace": ["type": "boolean", "description": "For type: replace what is in the field."],
                "keys": ["type": "string", "description": "For key: e.g. \"return\", \"escape\", \"tab\", \"down\", \"cmd+f\", \"cmd+shift+n\"."],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "For scroll."] as [String: Any],
                "amount": ["type": "integer", "description": "For scroll: lines (1–\(UIControl.maxScroll))."],
                "url": ["type": "string", "description": "For open in System Settings: a pane, e.g. x-apple.systempreferences:com.apple.Displays-Settings.extension"],
                "seconds": ["type": "number", "description": "For wait: seconds (at most \(Int(UIControl.maxWait)))."],
                "to_element": ["type": "string", "description": "For drag: label of the element to drop on, exactly as read_ui shows it."],
                "to_x": ["type": "number", "description": "For drag: screen x where it ends."],
                "to_y": ["type": "number", "description": "For drag: screen y where it ends."]
            ] as [String: Any],
            "required": ["action"]
        ]
        let steps: [String: Any] = ["type": "array", "description": "The steps, in order (at most \(UIControl.maxSteps)).", "items": step]
        let app: [String: Any] = ["type": "string", "description": "Name of the app to control, e.g. \"System Settings\" or \"Control Center\"."]
        return ["type": "object", "properties": ["app": app, "steps": steps] as [String: Any], "required": ["app", "steps"]]
    }

    // MARK: Plan lines

    static func summary(app: String, steps: [UIControl.Step]) -> String {
        let name = app.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? tr("control.frontApp") : name) + ": " + steps.map(describe).joined(separator: " → ")
    }

    /// One step in the user's language, complete: what is approved must be what is shown.
    static func describe(_ step: UIControl.Step) -> String {
        let place = step.element.map { "“\($0)”" + (step.index.map { " #\($0)" } ?? "") }
            ?? "\(Int(step.x ?? 0)),\(Int(step.y ?? 0))"
        switch step.action {
        case .click: return tr("control.step.click", place)
        case .doubleClick: return tr("control.step.doubleClick", place)
        case .rightClick: return tr("control.step.rightClick", place)
        case .type:
            let text = step.text ?? ""
            let line = tr(step.replace ? "control.step.replace" : "control.step.type", text)
            return step.element.map { line + " " + tr("control.step.in", $0) } ?? line
        case .key: return tr("control.step.key", step.keys ?? "")
        case .scroll: return tr("control.step.scroll", tr("control.direction.\(step.direction ?? "down")"), step.amount ?? 3)
        case .open: return step.url == nil ? tr("control.step.open") : tr("control.step.openPane", step.url ?? "")
        case .wait: return tr("control.step.wait", String(format: "%.1f", step.seconds ?? 1))
        case .drag:
            let target = step.toElement.map { "“\($0)”" } ?? "\(Int(step.toX ?? 0)),\(Int(step.toY ?? 0))"
            return tr("control.step.drag", place, target)
        case .hover: return tr("control.step.hover", place)
        }
    }

    // MARK: Running

    static func perform(app name: String, steps: [UIControl.Step]) async throws -> String {
        try checkAccess()
        let app = try await target(name)
        let appName = app.localizedName ?? name
        // Checked again here: the plan was approved a while ago, and this is what actually runs.
        guard !steps.isEmpty else { throw NookError(tr("control.error.noSteps")) }
        var problems = steps.enumerated().flatMap { offset, step in UIControl.problems(step).map { "Step \(offset + 1): \($0)" } }
        if steps.count > UIControl.maxSteps { problems.append("At most \(UIControl.maxSteps) steps at a time.") }
        guard problems.isEmpty else { throw NookError(problems.joined(separator: "; ")) }
        var done: [String] = []
        var notes: [String] = []
        for (offset, step) in steps.enumerated() {
            try Task.checkCancellation()
            do {
                if let note = try await run(step, in: app) { notes.append(note) }
            } catch {
                let finished = done.isEmpty ? "" : " " + tr("control.result.before", done.joined(separator: " → "))
                throw NookError(tr("control.error.step", offset + 1, error.localizedDescription) + finished)
            }
            done.append(describe(step))
            try? await Task.sleep(nanoseconds: settle)
        }
        let window = read(app).title ?? ""
        let result = tr("control.result", appName, done.joined(separator: " → "), window)
        return notes.isEmpty ? result : result + " " + notes.joined(separator: " ")
    }

    /// One step. Afterwards it checks what it can: typed text must show up in the field (else the step fails, so a form is
    /// never sent with something else in it); a switch or checkbox that did not change gives a note for the brain.
    private static func run(_ step: UIControl.Step, in app: NSRunningApplication) async throws -> String? {
        let name = app.localizedName ?? ""
        if step.action == .open {
            if let url = step.url.flatMap(URL.init(string:)), UIControl.isSettingsPane(url.absoluteString) {
                NSWorkspace.shared.open(url)
            }
            try await bringToFront(app)
            // Give the window (or pane) time to appear before the next step looks for it.
            for _ in 0..<15 {
                if !read(app).items.isEmpty { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return nil
        }
        if step.action == .wait {
            try? await Task.sleep(nanoseconds: UInt64(min(max(step.seconds ?? 1, 0.1), UIControl.maxWait) * 1_000_000_000))
            return nil
        }
        // Nothing comes to the front yet: a control that can press itself and a field that takes its value do so in
        // the background, so you keep working in your own window. Only the mouse and the keyboard need the app in front.
        let pid = app.processIdentifier

        // Where the step acts: a named element (looked up again now), or a point.
        var element: (element: UIControl.Element, ref: AXUIElement)?
        if let label = step.element {
            let items = read(app).items
            switch UIControl.match(label, role: step.role, index: step.index, in: items.map(\.element)) {
            case .success(let found):
                element = items.first { $0.element == found }
            case .failure(.ambiguous(_, let count)):
                throw NookError(tr("control.error.ambiguous", count, label))
            case .failure:
                throw NookError(tr("control.error.notFound", label, name))
            }
        }
        if let found = element?.element, !found.enabled, step.action != .scroll {
            throw NookError(tr("control.error.disabled", found.label))
        }
        let point: CGPoint? = element.map { CGPoint(x: $0.element.centerX, y: $0.element.centerY) }
            ?? step.x.flatMap { x in step.y.map { CGPoint(x: x, y: $0) } }
        if let point, step.action != .key { onAct?(point, element?.element.label ?? "") }

        switch step.action {
        case .click, .doubleClick, .rightClick:
            guard let point else { throw NookError(tr("control.error.noTarget")) }
            // A control that can press itself does so: no mouse needed, nothing in between can catch the click. Not a
            // web page's dropdown or menu button: its scripts open on the mouse going down, which a press never sends.
            let webMenu = browsers.contains(app.bundleIdentifier ?? "") && element.map { opensMenu($0) } == true
            if step.action == .click, !webMenu, let ref = element?.ref, !["row", "cell", "text"].contains(element?.element.role ?? ""),
               actions(of: ref).contains(kAXPressAction), AXUIElementPerformAction(ref, kAXPressAction as CFString) == .success {
                return await toggleNote(element)
            }
            if step.action == .rightClick, let ref = element?.ref, actions(of: ref).contains(kAXShowMenuAction),
               AXUIElementPerformAction(ref, kAXShowMenuAction as CFString) == .success {
                return nil
            }
            try await bringToFront(app)
            guard owns(point, pid: pid) else {
                // A sidebar row under another window (Nook's own panel) can still be selected directly.
                if step.action == .click, let found = element, ["row", "cell"].contains(found.element.role),
                   AXUIElementSetAttributeValue(found.ref, kAXSelectedAttribute as CFString, kCFBooleanTrue) == .success {
                    return nil
                }
                throw NookError(tr("control.error.covered", name))
            }
            await click(at: point, right: step.action == .rightClick, count: step.action == .doubleClick ? 2 : 1)
            if step.action == .click { return await toggleNote(element) }
        case .type:
            if let found = element, !found.element.secure, !browsers.contains(app.bundleIdentifier ?? ""),
               settable(found.ref), ["field", "textarea", "combobox", "search"].contains(found.element.role) {
                // In the background: the field takes the text as its value, read back to be sure.
                let before: String = attribute(found.ref, kAXValueAttribute) ?? ""
                let text = step.replace ? (step.text ?? "") : before + (step.text ?? "")
                if AXUIElementSetAttributeValue(found.ref, kAXValueAttribute as CFString, text as CFString) == .success,
                   let now: String = attribute(found.ref, kAXValueAttribute),
                   UIControl.typedLanded(step.text ?? "", value: now, replace: step.replace) {
                    return nil
                }
            }
            try await bringToFront(app)
            if let found = element {
                if found.element.secure { throw NookError(tr("control.error.secure")) }
                if AXUIElementSetAttributeValue(found.ref, kAXFocusedAttribute as CFString, kCFBooleanTrue) != .success {
                    guard let point, owns(point, pid: pid) else { throw NookError(tr("control.error.covered", name)) }
                    await click(at: point, right: false, count: 1)
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            if focusIsSecure(pid) { throw NookError(tr("control.error.secure")) }
            if step.replace, let all = UIControl.parseKeys("cmd+a") {
                try await press(all, in: app)
            }
            try await type(step.text ?? "", in: app)
            // Check the field itself (also the focused one when no element was named): the text must be in it now.
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Only real text fields: an editor the app draws itself often reports no value at all.
            let field = element?.ref ?? focusedElement(pid)
            let fieldRole: String? = field.flatMap { attribute($0, kAXRoleAttribute) }
            if let field, ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(fieldRole ?? ""),
               let value: String = attribute(field, kAXValueAttribute),
               !UIControl.typedLanded(step.text ?? "", value: value, replace: step.replace) {
                throw NookError(tr("control.error.notTyped", element?.element.label ?? tr("control.focusedField"), String(value.prefix(80))))
            }
        case .key:
            guard let combo = step.keys.flatMap(UIControl.parseKeys) else { throw NookError(tr("control.error.noTarget")) }
            try await bringToFront(app)
            try await press(combo, in: app)
        case .scroll:
            try await bringToFront(app)
            let at = point ?? frontWindowCenter(pid)
            guard let at, owns(at, pid: pid) else { throw NookError(tr("control.error.covered", name)) }
            scroll(at: at, direction: step.direction ?? "down", lines: min(max(step.amount ?? 3, 1), UIControl.maxScroll))
        case .hover:
            guard let point else { throw NookError(tr("control.error.noTarget")) }
            try await bringToFront(app)
            guard owns(point, pid: pid) else { throw NookError(tr("control.error.covered", name)) }
            let source = CGEventSource(stateID: .combinedSessionState)
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 700_000_000)
        case .drag:
            guard let point else { throw NookError(tr("control.error.noTarget")) }
            var end = step.toX.flatMap { x in step.toY.map { CGPoint(x: x, y: $0) } }
            if let label = step.toElement {
                let items = read(app).items
                switch UIControl.match(label, role: nil, index: nil, in: items.map(\.element)) {
                case .success(let found): end = CGPoint(x: found.centerX, y: found.centerY)
                case .failure(.ambiguous(_, let count)): throw NookError(tr("control.error.ambiguous", count, label))
                case .failure: throw NookError(tr("control.error.notFound", label, name))
                }
            }
            guard let end else { throw NookError(tr("control.error.noTarget")) }
            try await bringToFront(app)
            guard owns(point, pid: pid) else { throw NookError(tr("control.error.covered", name)) }
            await drag(from: point, to: end)
        case .open, .wait:
            break
        }
        return nil
    }

    // MARK: Looking

    /// A fresh picture of the app's window and the text seen on it with positions; the picture is kept for `takePicture`.
    static func look(_ app: NSRunningApplication) async -> String {
        guard let shot = await ScreenReader.windowImage(of: app, scale: 1) else {
            return "Nook could not take a picture of \(app.localizedName ?? "the app") (no window on screen, or screen recording is not allowed). Use read_ui."
        }
        picture = ChatImage.encode(shot.image)
        let frame = shot.frame
        var lines = ["Window of \(app.localizedName ?? "the app") at x \(Int(frame.minX)), y \(Int(frame.minY)), \(Int(frame.width))×\(Int(frame.height)) points. In the picture, pixel (px, py) is screen point (\(Int(frame.minX)) + px, \(Int(frame.minY)) + py)."]
        let seen = UIControl.describeSeen(await ScreenReader.seenLines(of: app, limit: 250), limit: 6_000)
        lines.append(seen.isEmpty ? "No text recognized in the window." : seen)
        return lines.joined(separator: "\n\n")
    }

    /// The name of the element at a screen point (top-left origin) in that app, as a person would call it: for the
    /// checkpoint of a click on a point. Nil when there is none, or it belongs to another app.
    static func label(at point: CGPoint, pid: pid_t) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(hit, &owner) == .success, owner == pid else { return nil }
        let role: String = attribute(hit, kAXRoleAttribute) ?? ""
        let name = label(of: hit, role: UIControl.role(role, subrole: attribute(hit, kAXSubroleAttribute)))
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// After a click on a checkbox, switch or radio button: a note when it still shows what it showed before (or a radio
    /// button that is still off), so the brain looks again instead of assuming it worked.
    private static func toggleNote(_ element: (element: UIControl.Element, ref: AXUIElement)?) async -> String? {
        guard let element, ["checkbox", "switch", "toggle", "radio"].contains(element.element.role) else { return nil }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let raw: CFTypeRef? = attribute(element.ref, kAXValueAttribute)
        guard let now = UIControl.stateText(role: element.element.role, value: raw) else { return nil }
        let unchanged = element.element.role == "radio" ? now != "on" : now == element.element.value
        return unchanged ? tr("control.note.unchanged", element.element.label, now) : nil
    }

    /// A dropdown, a menu button or a button that opens a popup (a web page's "Sort by").
    private static func opensMenu(_ element: (element: UIControl.Element, ref: AXUIElement)) -> Bool {
        if ["popup", "menubutton", "combobox"].contains(element.element.role) { return true }
        if let popup: String = attribute(element.ref, "AXHasPopup"), !["", "false"].contains(popup.lowercased()) { return true }
        if let popup: Bool = attribute(element.ref, "AXHasPopup"), popup { return true }
        return false
    }

    private static func settable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    private static func focusedElement(_ pid: pid_t) -> AXUIElement? {
        attribute(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
    }

    // MARK: The app

    static func checkAccess() throws {
        guard AXIsProcessTrusted() else { throw NookError(tr("control.error.accessibility")) }
    }

    /// The app by name (also roughly), started when it is closed; the front app when no name is given. Never one that
    /// `UIControl.isBlocked` names, and never Nook.
    static func target(_ name: String) async throws -> NSRunningApplication {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let app: NSRunningApplication
        if clean.isEmpty {
            guard let front = frontApp() else { throw NookError(tr("control.error.noApp")) }
            app = front
        } else {
            app = try await NookTools.menuTarget(clean)
        }
        let label = app.localizedName ?? clean
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier || app.bundleIdentifier == Bundle.main.bundleIdentifier
            || UIControl.isBlocked(app: label, bundleID: app.bundleIdentifier) {
            throw NookError(tr("control.error.blocked", label))
        }
        // Chromium browsers and Electron apps build the tree of a web page only for a client that asks for it.
        AutocompleteField.wake(app)
        return app
    }

    /// The app the user is working in: the front app, or while Nook's own chat has the focus, the app whose window is
    /// on top behind it.
    private static func frontApp() -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own { return front }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }), pid != own,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    /// The browser the user works in: the app in front when it is a browser, else the browser whose window is highest
    /// on screen, else one that runs. Nil when no browser runs (a page then opens in the default browser).
    static func userBrowser() -> NSRunningApplication? {
        let own = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own,
           browsers.contains(front.bundleIdentifier ?? "") {
            return front
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (window[kCGWindowOwnerPID as String] as? Int).map({ pid_t($0) }),
                  let app = NSRunningApplication(processIdentifier: pid), browsers.contains(app.bundleIdentifier ?? "") else { continue }
            return app
        }
        // No browser window on screen: the default browser when it runs, else any browser that runs.
        let running = NSWorkspace.shared.runningApplications.filter { browsers.contains($0.bundleIdentifier ?? "") }
        if let https = URL(string: "https://example.com"), let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: https),
           let match = running.first(where: { $0.bundleURL == defaultURL }) {
            return match
        }
        return running.first
    }

    private static func bringToFront(_ app: NSRunningApplication) async throws {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        // A system agent never comes to the front: its panel shows over the app that is.
        if app.activationPolicy != .regular { return }
        app.activate()
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return }
        }
        throw NookError(tr("control.error.notFront", app.localizedName ?? ""))
    }

    /// Keys only go out while the approved app is in front: when something else took over (a dialog of another app,
    /// the user switching away), the step stops instead of typing there.
    private static func ensureFront(_ app: NSRunningApplication) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw NookError(tr("control.error.notFront", app.localizedName ?? ""))
        }
    }

    // MARK: Reading the window

    /// A read that gives a just-woken browser or a window that is still loading a moment to fill in its tree.
    static func settledRead(_ app: NSRunningApplication) async -> Window {
        var window = read(app)
        for _ in 0..<4 where window.items.filter({ UIControl.tier($0.element.role) <= 1 }).count < UIControl.fewControls {
            try? await Task.sleep(nanoseconds: 250_000_000)
            window = read(app)
        }
        return window
    }

    struct Window {
        var title: String?
        var items: [(element: UIControl.Element, ref: AXUIElement)]
    }

    /// Enough for a long web page; what reaches the brain is trimmed by `UIControl.describe`, fields and buttons first.
    private static let maxElements = 900
    /// Of those, at most this many scrolled out of view: a long filter list above a shop's products must not use up
    /// the room before the products in view are reached.
    private static let maxOffscreen = 300
    private static let maxDepth = 40

    /// The elements of the app's windows, focused window first, in the order they appear in the tree.
    static func read(_ app: NSRunningApplication) -> Window {
        let root = AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetMessagingTimeout(root, 1.5)
        var windows: [AXUIElement] = []
        if let focused: AXUIElement = attribute(root, kAXFocusedWindowAttribute) { windows.append(focused) }
        for window in (attribute(root, kAXWindowsAttribute) as [AXUIElement]?) ?? [] where !windows.contains(where: { CFEqual($0, window) }) {
            windows.append(window)
        }
        let title: String? = windows.first.flatMap { attribute($0, kAXTitleAttribute) }
        var items: [(element: UIControl.Element, ref: AXUIElement)] = []
        let focusedElement: AXUIElement? = attribute(root, kAXFocusedUIElementAttribute)
        // An open dropdown's menu (a web page's "Sort by") hangs off the app, not the window: its options come first.
        for menu in (attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] where (attribute(menu, kAXRoleAttribute) as String?) == kAXMenuRole {
            collect(menu, depth: 0, focused: focusedElement, bounds: nil, into: &items)
        }
        for window in windows.prefix(4) {
            collect(window, depth: 0, focused: focusedElement, bounds: frame(of: window), into: &items)
            if items.count >= maxElements { break }
        }
        // A system agent (Control Center) has no window until one of its menu bar items is clicked: those items come
        // after its open panel, so Focus, Wi-Fi and Bluetooth can be reached from the menu bar.
        if AppNames.systemAgents.contains(app.bundleIdentifier ?? ""),
           let extras: AXUIElement = attribute(root, kAXExtrasMenuBarAttribute) {
            for item in (attribute(extras, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                collect(item, depth: 1, focused: focusedElement, bounds: nil, into: &items)
            }
        }
        return Window(title: title, items: items)
    }

    /// `bounds` is the window's frame: an element outside it is scrolled out of view (nil: everything counts as in view).
    private static func collect(_ element: AXUIElement, depth: Int, focused: AXUIElement?, bounds: CGRect?,
                                into items: inout [(element: UIControl.Element, ref: AXUIElement)]) {
        guard depth <= maxDepth, items.count < maxElements else { return }
        let axRole: String = attribute(element, kAXRoleAttribute) ?? ""
        if axRole == kAXMenuBarRole { return }
        let subrole: String? = attribute(element, kAXSubroleAttribute)
        let role = UIControl.role(axRole, subrole: subrole)
        if UIControl.listedRoles.contains(role), let frame = frame(of: element), frame.width > 0, frame.height > 0 {
            let secure = role == "password"
            var rawValue: CFTypeRef?
            if !secure { rawValue = attribute(element, kAXValueAttribute) }
            var name = label(of: element, role: role)
            var value = role == "text" ? nil : UIControl.stateText(role: role, value: rawValue)
            if role == "text" { name = UIControl.stateText(role: role, value: rawValue) ?? name }
            if value == name { value = nil }
            let visible = bounds.map { $0.intersects(frame) } ?? true
            let roomLeft = visible || items.filter { !$0.element.visible }.count < maxOffscreen
            if roomLeft, !name.isEmpty || ["field", "search", "textarea", "password", "combobox", "slider", "switch", "checkbox"].contains(role) {
                let enabled: Bool = attribute(element, kAXEnabledAttribute) ?? true
                items.append((UIControl.Element(
                    role: role, label: name.isEmpty ? "(\(role))" : String(name.prefix(120)), value: value.map { String($0.prefix(200)) },
                    x: Double(frame.minX), y: Double(frame.minY), width: Double(frame.width), height: Double(frame.height),
                    enabled: enabled, focused: focused.map { CFEqual($0, element) } ?? false, secure: secure, visible: visible
                ), element))
            }
            // A row's or cell's texts are its label already; a button holds nothing worth listing.
            if ["row", "cell", "button", "checkbox", "switch", "radio", "link", "text", "menuitem"].contains(role) { return }
        }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            collect(child, depth: depth + 1, focused: focused, bounds: bounds, into: &items)
            if items.count >= maxElements { return }
        }
    }

    /// The name a person sees for an element: its title, its description, the text of the label next to it, the first
    /// text inside a row, or the texts inside a link or button (a web page's product link holds its name and no title).
    private static func label(of element: AXUIElement, role: String) -> String {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text: String = attribute(element, name), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let titled: AXUIElement = attribute(element, kAXTitleUIElementAttribute),
           let text: String = attribute(titled, kAXValueAttribute), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if ["row", "cell"].contains(role), let text = firstText(in: element, depth: 0) { return text }
        if ["link", "button", "menuitem"].contains(role) {
            var texts: [String] = []
            innerTexts(in: element, depth: 0, into: &texts)
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        if let placeholder: String = attribute(element, "AXPlaceholderValue"), !placeholder.isEmpty { return placeholder }
        if let help: String = attribute(element, kAXHelpAttribute), !help.isEmpty, role != "text" { return help }
        return ""
    }

    private static func firstText(in element: AXUIElement, depth: Int) -> String? {
        guard depth < 5 else { return nil }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            let role: String = attribute(child, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole, let text: String = attribute(child, kAXValueAttribute),
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let text = firstText(in: child, depth: depth + 1) { return text }
        }
        return nil
    }

    /// The texts inside an element in reading order, until there is enough for a label.
    private static func innerTexts(in element: AXUIElement, depth: Int, into texts: inout [String]) {
        guard depth < 6, texts.count < 4, texts.joined(separator: " ").count < 120 else { return }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            let role: String = attribute(child, kAXRoleAttribute) ?? ""
            if role == kAXStaticTextRole, let text: String = attribute(child, kAXValueAttribute) {
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { texts.append(clean) }
            } else if role == kAXImageRole, let alt: String = attribute(child, kAXDescriptionAttribute) {
                let clean = alt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { texts.append(clean) }
            } else {
                innerTexts(in: child, depth: depth + 1, into: &texts)
            }
            if texts.count >= 4 { return }
        }
    }

    private static func focusIsSecure(_ pid: pid_t) -> Bool {
        let root = AXUIElementCreateApplication(pid)
        guard let focused: AXUIElement = attribute(root, kAXFocusedUIElementAttribute) else { return false }
        let subrole: String? = attribute(focused, kAXSubroleAttribute)
        return subrole == kAXSecureTextFieldSubrole
    }

    private static func frontWindowCenter(_ pid: pid_t) -> CGPoint? {
        let root = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = attribute(root, kAXFocusedWindowAttribute), let frame = frame(of: window) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: Accessibility values

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        guard let positionValue: CFTypeRef = attribute(element, kAXPositionAttribute), CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue: CFTypeRef = attribute(element, kAXSizeAttribute), CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    // MARK: Mouse and keyboard

    /// Whether the app's own window is the one on top at this point: a click there cannot land in another app (or on
    /// Nook's own panel, whose Run button it could otherwise press).
    static func owns(_ point: CGPoint, pid: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            if let alpha = window[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { continue }
            guard let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point) else { continue }
            return (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) == pid } ?? false
        }
        return false
    }

    private static func click(at point: CGPoint, right: Bool, count: Int) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        let button: CGMouseButton = right ? .right : .left
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000)
        for click in 1...max(count, 1) {
            for type in [down, up] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event.setIntegerValueField(.eventSourceUserData, value: AutocompleteTyper.marker)
                event.post(tap: .cghidEventTap)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    /// Presses at one point, moves there in small steps the way a hand does (apps only follow a drag that moves), and
    /// releases at the other.
    private static func drag(from start: CGPoint, to end: CGPoint) async {
        let source = CGEventSource(stateID: .combinedSessionState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
            event.setIntegerValueField(.eventSourceUserData, value: AutocompleteTyper.marker)
            event.post(tap: .cghidEventTap)
        }
        post(.mouseMoved, start)
        try? await Task.sleep(nanoseconds: 60_000_000)
        post(.leftMouseDown, start)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let steps = 20
        for index in 1...steps {
            let t = CGFloat(index) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        try? await Task.sleep(nanoseconds: 150_000_000)
        post(.leftMouseUp, end)
    }

    private static func press(_ combo: UIControl.KeyCombo, in app: NSRunningApplication) async throws {
        try ensureFront(app)
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.code), keyDown: isDown) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: AutocompleteTyper.marker)
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Types with key events that carry the characters themselves (any language, no clipboard), a few at a time, and
    /// stops as soon as the app is no longer in front.
    private static func type(_ text: String, in app: NSRunningApplication) async throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            try ensureFront(app)
            var end = min(start + 16, units.count)
            // Never between the halves of a surrogate pair.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let piece = Array(units[start..<end])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                event.setIntegerValueField(.eventSourceUserData, value: AutocompleteTyper.marker)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
            start = end
        }
    }

    private static func scroll(at point: CGPoint, direction: String, lines: Int) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        let amount = Int32(lines)
        let vertical: Int32 = direction == "up" ? amount : (direction == "down" ? -amount : 0)
        let horizontal: Int32 = direction == "left" ? amount : (direction == "right" ? -amount : 0)
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        event.location = point
        event.setIntegerValueField(.eventSourceUserData, value: AutocompleteTyper.marker)
        event.post(tap: .cghidEventTap)
    }
}
