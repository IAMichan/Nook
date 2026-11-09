import Foundation

// A page an agent shows inline in its session's timeline (`render_page` on the bridge): a chart, a diagram, a mock-up.
// Kept as a file with the session and drawn by `RenderedPageRow` in the same sandbox as an MCP app's page, but with
// nothing to talk to: no network, no messages to Nook, no forms, popups or navigation, at a fixed, capped height. The
// page is untrusted, like every tool output. Foundation only, so the rules are tested here (`RenderedPageTests`).

enum RenderedPage {
    /// The event's `tool`: what marks a `.page` event as one of these.
    static let tool = "render_page"
    static let maxHTMLBytes = 512 * 1024
    static let maxTitleLength = 120
    static let defaultHeight = 360.0
    static let minHeight = 80.0
    static let maxHeight = 1200.0
    /// How many pages one session keeps: enough for a few rounds of a chart, never an endless stream of files.
    static let maxPagesPerRun = 24

    struct Request: Equatable, Sendable {
        var html: String
        var title: String
        var height: Double
    }

    static func parse(_ arguments: [String: Any]) -> Result<Request, BridgeArgumentError> {
        guard let html = arguments["html"] as? String, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(BridgeArgumentError("Give the page as html: a complete HTML document or fragment."))
        }
        guard html.utf8.count <= maxHTMLBytes else {
            return .failure(BridgeArgumentError("The page is too large (at most \(maxHTMLBytes / 1024) KB). Inline less data, or draw it with fewer elements."))
        }
        let title = BridgeArgs.string(arguments["title"]).map { String($0.components(separatedBy: .newlines).joined(separator: " ").prefix(maxTitleLength)) }
        return .success(Request(html: html, title: title ?? "Page", height: clamp(BridgeArgs.int(arguments["height"]).map(Double.init))))
    }

    static func clamp(_ height: Double?) -> Double {
        guard let height, height.isFinite else { return defaultHeight }
        return min(maxHeight, max(minHeight, height)).rounded()
    }

    /// Where a session's pages are kept: one folder per session, one file per page.
    static func file(in base: URL, run: UUID, page: UUID) -> URL {
        base.appendingPathComponent("pages", isDirectory: true)
            .appendingPathComponent(run.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(page.uuidString.lowercased() + ".html")
    }

    /// The timeline's record of a page: its title, the file it is kept in and its height.
    static func event(id: UUID = UUID(), title: String, file: String, height: Double) -> RunEvent {
        RunEvent(kind: .page, text: title, tool: tool, detail: file, output: String(Int(clamp(height))), id: id)
    }

    static func height(of event: RunEvent) -> Double { clamp(event.output.flatMap(Double.init)) }

    /// The tallest a page is shown at its full size in the conversation: a very long page reads better in the side panel.
    static let maxFullHeight = 4000.0

    /// How tall a page's frame is: the height the agent asked for, or less when the page turned out shorter (no empty
    /// room under it); at full size the whole page, up to `maxFullHeight`. Until it was measured, the agent's height.
    static func shownHeight(asked: Double, measured: Double?, fullSize: Bool) -> Double {
        guard let measured, measured.isFinite, measured > 0 else { return asked }
        let page = max(minHeight, measured.rounded(.up))
        return fullSize ? min(maxFullHeight, max(asked, page)) : min(asked, page)
    }

    /// A page file in the folder Nook keeps pages in under `base`, never a path elsewhere: an event read back from disk is
    /// not trusted to point anywhere else.
    static func isOwnFile(_ path: String, base: URL) -> Bool {
        let folder = base.appendingPathComponent("pages", isDirectory: true).standardizedFileURL.path + "/"
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        return file.hasPrefix(folder) && file.hasSuffix(".html")
    }

    /// What the web view loads: a static page around a sandboxed frame (`allow-scripts` only, so an opaque origin with
    /// no forms, popups, top navigation or storage), holding the page under the MCP app policy without any declared
    /// origin (`McpApp.prepared`): nothing loads or connects anywhere. The outer page has no script and no handler.
    static func hostPage(_ html: String) -> String {
        let inner = McpApp.prepared(html, csp: nil)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><iframe sandbox="allow-scripts" referrerpolicy="no-referrer" srcdoc="\(inner)"></iframe></body></html>
        """
    }

    /// How large a page is drawn, read by a script in a content world of Nook's own: the page's scripts share its
    /// document but not its world, so they can neither see the handler nor send through it.
    enum Measure {
        static let handler = "nookPageSize"
        /// Never smaller than this: a page that needs more zoom than this to fit is better scrolled sideways.
        static let minZoom = 0.4

        struct Size: Equatable {
            let width: Double
            let viewport: Double
            let height: Double

            init?(_ body: Any) {
                guard let values = body as? [String: Any],
                      let width = (values["w"] as? NSNumber)?.doubleValue, let viewport = (values["v"] as? NSNumber)?.doubleValue,
                      let height = (values["h"] as? NSNumber)?.doubleValue,
                      width.isFinite, viewport.isFinite, height.isFinite, viewport > 0 else { return nil }
                self.width = width
                self.viewport = viewport
                self.height = height
            }
        }

        /// The zoom at which the page's width fits its frame: lower while it is wider than the frame, never above 1.
        static func zoom(current: Double, _ size: Size) -> Double {
            guard size.width > size.viewport + 1 else { return current }
            return max(minZoom, min(1, current * size.viewport / size.width))
        }

        /// Reports the document's scroll width, its viewport's width and its intrinsic content height whenever its
        /// width or content changes. Resizing the frame's height (for instance when toggling full size) changes only
        /// `clientHeight`, which is ignored so viewport-relative styles (`100vh`, `calc(100vh - …)`, `height: 100%`)
        /// never feed back into the measured height and grow the frame in a loop.
        static let source = """
        (() => {
          if (window === window.top) return;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handler);
          if (!handler) return;
          const vhRe = /(?:^|[^a-z])(?:d|s|l)?v[hb]\\b/i, pctRe = /%/, pxRe = /[0-9]px\\b/i;
          let queued = false, lastWidth = 0, lastHeight = 0, initialWidth = 0, initialHeight = 0;
          const report = () => {
            queued = false;
            const root = document.documentElement, body = document.body;
            if (!root || !body || root.clientWidth <= 0) return;
            if (initialWidth <= 0) { initialWidth = root.clientWidth; initialHeight = root.clientHeight; }
            lastWidth = root.clientWidth;
            lastHeight = root.clientHeight;
            const vhNodes = new Set(), pctNodes = new Set(), pxNodes = new Set();
            const checkStyle = (style, addVh, addPct, addPx) => {
              if (!style) return;
              const v = (style.height || "") + " " + (style.minHeight || "") + " " + (style.maxHeight || "");
              if (vhRe.test(v)) addVh();
              else if (pctRe.test(v)) addPct();
              else if (pxRe.test(v)) addPx();
            };
            const scanRules = (rules) => {
              if (!rules) return;
              for (const rule of rules) {
                if (rule.style && rule.selectorText) {
                  const select = (set) => { try { document.querySelectorAll(rule.selectorText).forEach(n => set.add(n)); } catch {} };
                  checkStyle(rule.style, () => select(vhNodes), () => select(pctNodes), () => select(pxNodes));
                }
                if (rule.cssRules) { try { scanRules(rule.cssRules); } catch {} }
              }
            };
            for (const sheet of document.styleSheets) { try { scanRules(sheet.cssRules); } catch {} }
            document.querySelectorAll("[style]").forEach(el => {
              checkStyle(el.style, () => vhNodes.add(el), () => pctNodes.add(el), () => pxNodes.add(el));
            });
            const viewportNodes = new Set(vhNodes);
            if (pctNodes.has(root) || pctNodes.has(body)) { viewportNodes.add(root); viewportNodes.add(body); }
            let added = true;
            while (added) {
              added = false;
              for (const el of pctNodes) {
                if (!viewportNodes.has(el) && el.parentElement && viewportNodes.has(el.parentElement)) {
                  viewportNodes.add(el);
                  added = true;
                }
              }
            }
            const usesViewport = viewportNodes.size > 0;
            const unconstrain = new Set([root, body, ...viewportNodes]);
            if (usesViewport) {
              body.querySelectorAll("*").forEach(el => {
                const oy = getComputedStyle(el).overflowY;
                if (oy !== "auto" && oy !== "scroll") return;
                let p = el, inside = false, fixed = false;
                const chain = [];
                while (p && p !== body && p !== root) {
                  chain.push(p);
                  if (viewportNodes.has(p)) { inside = true; break; }
                  if (pxNodes.has(p)) { fixed = true; break; }
                  p = p.parentElement;
                }
                if (!fixed && (inside || viewportNodes.has(body) || viewportNodes.has(root))) {
                  chain.forEach(n => unconstrain.add(n));
                }
              });
            }
            const winX = window.scrollX, winY = window.scrollY;
            const saved = [];
            for (const el of unconstrain) {
              saved.push([el, el.getAttribute("style"), el.scrollTop, el.scrollLeft]);
              el.style.setProperty("height", "auto", "important");
              el.style.setProperty("min-height", "0", "important");
              el.style.setProperty("max-height", "none", "important");
              el.style.setProperty("flex-basis", "auto", "important");
              el.style.setProperty("overflow-y", "visible", "important");
            }
            const contentHeight = Math.max(
              root.getBoundingClientRect().height,
              body.getBoundingClientRect().height,
              body.scrollHeight,
              body.offsetHeight
            );
            for (const [el, attr] of saved) {
              if (attr === null) el.removeAttribute("style");
              else el.setAttribute("style", attr);
            }
            for (const [el, , top, left] of saved) {
              if (top) el.scrollTop = top;
              if (left) el.scrollLeft = left;
            }
            if (winX || winY) window.scrollTo(winX, winY);
            mutations.takeRecords();
            const viewport = root.clientWidth;
            const width = Math.max(root.scrollWidth, body.scrollWidth);
            const floor = usesViewport && initialWidth > 0 ? initialHeight * (viewport / initialWidth) : 0;
            const height = Math.max(floor, contentHeight);
            handler.postMessage({ w: width, v: viewport, h: height });
          };
          const queue = () => { if (!queued) { queued = true; setTimeout(report, 16); } };
          const onResize = () => {
            const root = document.documentElement;
            if (!root) return;
            if (lastWidth > 0 && root.clientWidth === lastWidth && root.clientHeight !== lastHeight) {
              lastHeight = root.clientHeight;
              return;
            }
            queue();
          };
          const observer = new ResizeObserver(onResize);
          observer.observe(document.documentElement);
          if (document.body) observer.observe(document.body);
          const mutations = new MutationObserver(queue);
          mutations.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
          window.addEventListener("load", queue);
          queue();
        })();
        """
    }
}
