import AppKit
import SwiftUI
import WebKit

/// What a page asks of you in Nook's browser, answered as in Safari: its `alert`, `confirm` and `prompt` as a sheet on the
/// window with the site's name, its "Choose file" as the open panel, and its wish for your camera or microphone as a
/// question you can answer once for the site. Shared by the tabs (`BrowserPage`) and the
/// windows pages open (`BrowserSitePopup`). Without these WebKit answered for you: no message, "Cancel" to every
/// question, and no file.
@MainActor
enum BrowserPageDialogs {
    static func alert(_ message: String, frame: WKFrameInfo, in webView: WKWebView) async {
        let alert = make(message, frame: frame)
        alert.addButton(withTitle: tr("button.ok"))
        _ = await run(alert, in: webView)
    }

    static func confirm(_ message: String, frame: WKFrameInfo, in webView: WKWebView) async -> Bool {
        let alert = make(message, frame: frame)
        alert.addButton(withTitle: tr("button.ok"))
        alert.addButton(withTitle: tr("button.cancel"))
        return await run(alert, in: webView) == .alertFirstButtonReturn
    }

    static func prompt(_ message: String, defaultText: String?, frame: WKFrameInfo, in webView: WKWebView) async -> String? {
        let alert = make(message, frame: frame)
        alert.addButton(withTitle: tr("button.ok"))
        alert.addButton(withTitle: tr("button.cancel"))
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await run(alert, in: webView) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// A file field on the page: the open panel, with folders and several files when the field takes them.
    static func chooseFiles(_ parameters: WKOpenPanelParameters, in webView: WKWebView) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        if let window = webView.window {
            return await withCheckedContinuation { done in
                panel.beginSheetModal(for: window) { response in done.resume(returning: response == .OK ? panel.urls : nil) }
            }
        }
        return panel.runModal() == .OK ? panel.urls : nil
    }

    /// A name for a bookmark or folder, asked over the key window; nil when you cancel.
    static func askName(_ title: String, value: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: tr("button.ok"))
        alert.addButton(withTitle: tr("button.cancel"))
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await withCheckedContinuation { done in alert.beginSheetModal(for: window) { done.resume(returning: $0) } }
        } else {
            response = alert.runModal()
        }
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// A site asks for your camera or microphone: the answer you saved for it (`BrowserSitePermissions`), or else a
    /// question naming the site and what it wants, with "Remember for this site". macOS asks Nook for the device itself
    /// the first time on top of this.
    static func media(_ type: WKMediaCaptureType, origin: WKSecurityOrigin, in webView: WKWebView) async -> WKPermissionDecision {
        let kinds: [BrowserSitePermissions.Kind]
        let questionKey: String
        switch type {
        case .camera: (kinds, questionKey) = ([.camera], "browser.permission.camera")
        case .microphone: (kinds, questionKey) = ([.microphone], "browser.permission.microphone")
        case .cameraAndMicrophone: (kinds, questionKey) = ([.camera, .microphone], "browser.permission.cameraAndMicrophone")
        @unknown default: return .prompt
        }
        let host = origin.host
        if let saved = BrowserSitePermissions.shared.decision(host: host, kinds: kinds) { return saved ? .grant : .deny }
        let alert = NSAlert()
        alert.messageText = tr(questionKey, host)
        alert.informativeText = tr("browser.permission.detail")
        alert.addButton(withTitle: tr("browser.permission.allow"))
        alert.addButton(withTitle: tr("browser.permission.deny"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = tr("browser.permission.remember")
        let allowed = await run(alert, in: webView) == .alertFirstButtonReturn
        if alert.suppressionButton?.state == .on {
            BrowserSitePermissions.shared.remember(host: host, kinds: kinds, allowed: allowed)
        }
        return allowed ? .grant : .deny
    }

    private static func make(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? tr("browser.dialog.page") : tr("browser.dialog.from", host)
        alert.informativeText = message
        return alert
    }

    private static func run(_ alert: NSAlert, in webView: WKWebView) async -> NSApplication.ModalResponse {
        guard let window = webView.window else { return alert.runModal() }
        return await withCheckedContinuation { done in
            alert.beginSheetModal(for: window) { done.resume(returning: $0) }
        }
    }
}

/// Finding on the page (⌘F): a bar under the toolbar with a field, the previous and next match, and a close button.
/// Return goes to the next match, Shift-Return to the previous one; Escape clears the field, and closes the bar once it
/// is empty.
struct BrowserFindBar: View {
    let webView: WKWebView
    @Binding var text: String
    /// The last ⌘F (step 0), ⌘G (1) or ⌘⇧G (-1) on the page: the field takes the cursor again, and ⌘G or ⌘⇧G goes to
    /// the next or previous match.
    let request: Request
    let close: () -> Void
    @State private var notFound = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: NookTheme.Spacing.xs) {
            NookSearchField(prompt: tr("browser.find.placeholder"), text: $text, style: .inline, focus: $focused,
                            onSubmit: { find(backwards: NSEvent.modifierFlags.contains(.shift)) }, onEscape: close)
                .onChange(of: text) { _, _ in find(backwards: false, fromStart: true) }
            if notFound {
                Text(tr("browser.find.none"))
                    .font(NookTheme.TextStyle.detail)
                    .foregroundStyle(NookTheme.coral)
                    .fixedSize()
            }
            ToolbarIconButton("chevron.up", tr("browser.find.previous"), height: 22, width: 22, enabled: !text.isEmpty) {
                find(backwards: true)
            }
            ToolbarIconButton("chevron.down", tr("browser.find.next"), height: 22, width: 22, enabled: !text.isEmpty) {
                find(backwards: false)
            }
            ToolbarIconButton("xmark", tr("browser.find.close"), height: 22, width: 22, close)
        }
        .padding(.horizontal, NookTheme.Spacing.lg)
        .frame(height: SidePanelMetrics.toolbar)
        .onAppear { focused = true }
        .onChange(of: request) { _, request in
            focused = true
            if request.step != 0 { find(backwards: request.step < 0) }
        }
    }

    struct Request: Equatable {
        var count = 0
        var step = 0
    }

    /// Lights the next (or previous) match and scrolls to it. While you type the search starts over from the top, so
    /// the first match is lit rather than the one after the last.
    private func find(backwards: Bool, fromStart: Bool = false) {
        guard !text.isEmpty else {
            notFound = false
            return
        }
        if fromStart { webView.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", completionHandler: nil) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        webView.find(text, configuration: configuration) { result in notFound = !result.matchFound }
    }
}
