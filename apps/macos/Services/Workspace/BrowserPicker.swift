import Foundation

// Pointing at an element in Nook's browser, and the servers on this Mac the empty browser offers.
// Foundation only, so tests can use it independently.

/// An element you selected in Nook's browser. Everything but the address comes from the page, so it is data, never an
/// order.
struct PickedElement: Equatable, Sendable {
    var url: String
    /// Where it sits: a CSS selector that finds it again (`main > section:nth-of-type(2) > h2`).
    var selector: String
    /// Its visible text.
    var text: String
    /// What the picker's badge shows: the tag with its first classes (`h2.mkt-title`), or its id (`button#buy`).
    var label: String = ""
    /// Its own markup, clipped (`BrowserPickScript.htmlLimit`).
    var html: String = ""

    /// The name of its tile in the composer.
    var name: String {
        let shown = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return shown.isEmpty ? selector : shown
    }

    /// What the agent (or the chat) reads: where the element is, its markup as code, and its text.
    var snippet: String {
        var lines = ["Element `\(name)` on \(url)", "Selector: `\(selector)`"]
        let markup = html.trimmingCharacters(in: .whitespacesAndNewlines)
        if !markup.isEmpty {
            // A fence longer than any run of backticks in the markup, so the page can never close it.
            let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(in: markup) + 1))
            lines += ["", fence + "html", markup, fence]
        }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty, words != markup { lines += ["", "Text:", words] }
        return lines.joined(separator: "\n")
    }

    /// The composer's tile for this element, with `id` as the key of its snippet.
    func reference(id: String) -> ContextRef {
        ContextRef(kind: .element, id: id, label: name)
    }

    /// Several selected elements as one attachment for the chat, which holds one at a time.
    static func combined(_ elements: [PickedElement]) -> (name: String, text: String)? {
        guard let first = elements.first else { return nil }
        let name = elements.count == 1 ? first.name : "\(first.name) +\(elements.count - 1)"
        return (name, elements.map(\.snippet).joined(separator: "\n\n---\n\n"))
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }
}

enum BrowserPickScript {
    /// The most visible text a selected element brings along.
    static let textLimit = 1500
    /// The most markup a selected element brings along; a whole page section is clipped with a note.
    static let htmlLimit = 6000

    /// Body for `callAsyncJavaScript`: while the pointer moves, the element under it gets an outline with a badge that
    /// names it (`h2.mkt-title`); a click resolves with that element and leaves a mark on it, so you see what you already
    /// took. Escape or `cancel` resolves with null. Clicks while selecting never reach the page. Call it again to select
    /// the next one; `clear` takes the marks away.
    static let pick = """
    return await new Promise((resolve) => {
      const iris = '#7c6cf0';
      const layer = () => {
        let root = document.getElementById('__nook-pick-layer');
        if (!root) {
          root = document.createElement('div');
          root.id = '__nook-pick-layer';
          root.style.cssText = 'position:absolute;left:0;top:0;width:0;height:0;z-index:2147483647;pointer-events:none';
          document.documentElement.appendChild(root);
        }
        return root;
      };
      const name = (element) => {
        const tag = element.tagName.toLowerCase();
        if (element.id) return tag + '#' + element.id;
        const classes = typeof element.className === 'string'
          ? element.className.trim().split(/\\s+/).filter((c) => c && !c.startsWith('__nook')).slice(0, 2) : [];
        return classes.length ? tag + '.' + classes.join('.') : tag;
      };
      const frame = (filled) => {
        const box = document.createElement('div');
        box.style.cssText = 'position:absolute;box-sizing:border-box;border:1.5px solid ' + iris + ';border-radius:3px;' +
          'background:' + (filled ? 'rgba(124,108,240,.14)' : 'rgba(124,108,240,.06)') + ';display:none';
        const badge = document.createElement('div');
        badge.style.cssText = 'position:absolute;left:-1.5px;bottom:100%;margin-bottom:3px;padding:1px 6px;border-radius:4px;' +
          'background:' + iris + ';color:#fff;font:600 11px/16px -apple-system,system-ui,sans-serif;white-space:nowrap;' +
          'max-width:320px;overflow:hidden;text-overflow:ellipsis';
        box.appendChild(badge);
        layer().appendChild(box);
        return { box, badge };
      };
      const place = (shown, element) => {
        const r = element.getBoundingClientRect();
        shown.box.style.display = 'block';
        shown.box.style.left = (r.left + window.scrollX) + 'px';
        shown.box.style.top = (r.top + window.scrollY) + 'px';
        shown.box.style.width = r.width + 'px';
        shown.box.style.height = r.height + 'px';
        shown.badge.textContent = name(element);
        // No room above the element: the badge goes inside its top edge.
        if (r.top < 22) { shown.badge.style.bottom = 'auto'; shown.badge.style.top = '2px'; shown.badge.style.left = '2px'; }
        else { shown.badge.style.bottom = '100%'; shown.badge.style.top = 'auto'; shown.badge.style.left = '-1.5px'; }
      };
      const hover = frame(true);
      let current = null;
      const selector = (element) => {
        if (element.id) return '#' + CSS.escape(element.id);
        const parts = [];
        for (let node = element; node && node.nodeType === 1 && node !== document.body && parts.length < 5; node = node.parentElement) {
          if (node.id) { parts.unshift('#' + CSS.escape(node.id)); break; }
          const same = node.parentElement ? [...node.parentElement.children].filter((c) => c.tagName === node.tagName) : [];
          const tag = node.tagName.toLowerCase();
          parts.unshift(same.length > 1 ? tag + ':nth-of-type(' + (same.indexOf(node) + 1) + ')' : tag);
        }
        return parts.length ? parts.join(' > ') : element.tagName.toLowerCase();
      };
      const move = (event) => {
        const found = document.elementFromPoint(event.clientX, event.clientY);
        if (!found || found === document.documentElement || found.closest('#__nook-pick-layer')) return;
        current = found;
        place(hover, current);
      };
      const stop = (event) => { event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation(); };
      const finish = (value) => {
        window.removeEventListener('mousemove', move, true);
        ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu'].forEach((n) => window.removeEventListener(n, stop, true));
        window.removeEventListener('click', click, true);
        window.removeEventListener('keydown', key, true);
        hover.box.remove();
        document.documentElement.style.cursor = previousCursor;
        delete window.__nookCancelPick;
        resolve(value);
      };
      const click = (event) => {
        stop(event);
        if (!current) return finish(null);
        const mark = frame(false);
        place(mark, current);
        mark.box.setAttribute('data-nook-mark', '');
        const text = (current.innerText || current.getAttribute('aria-label') || current.getAttribute('alt') || '').trim();
        let html = current.outerHTML || '';
        if (html.length > \(htmlLimit)) html = html.slice(0, \(htmlLimit)) + '\\n<!-- … clipped -->';
        finish({ selector: selector(current), label: name(current), text: text.slice(0, \(textLimit)), html: html });
      };
      const key = (event) => { if (event.key === 'Escape') { stop(event); finish(null); } };
      const previousCursor = document.documentElement.style.cursor;
      document.documentElement.style.cursor = 'crosshair';
      window.addEventListener('mousemove', move, true);
      ['mousedown', 'mouseup', 'pointerdown', 'pointerup', 'dblclick', 'contextmenu'].forEach((n) => window.addEventListener(n, stop, true));
      window.addEventListener('click', click, true);
      window.addEventListener('keydown', key, true);
      window.__nookCancelPick = () => finish(null);
    });
    """

    static let cancel = "if (window.__nookCancelPick) { window.__nookCancelPick(); }"

    /// Takes the marks of what you selected off the page again.
    static let clear = "(() => { const layer = document.getElementById('__nook-pick-layer'); if (layer) { layer.remove(); } })();"
}

/// A server listening on this Mac that you may be working on.
struct LocalServer: Identifiable, Equatable, Sendable {
    var port: Int
    var process: String

    var id: Int { port }
    var address: String { "http://localhost:\(port)" }
}

enum LocalServers {
    /// What a development server runs in. Everything else that listens (mail, sync, the system) is not offered.
    private static let processes = ["node", "bun", "deno", "python", "ruby", "php", "java", "go", "vite", "next", "rails",
                                    "uvicorn", "gunicorn", "nginx", "caddy", "dotnet", "beam", "hugo", "astro", "wrangler", "workerd"]

    /// The output of `lsof -nP -iTCP -sTCP:LISTEN -FcnP`: a `c` line names the process, an `n` line an address. Reachable
    /// addresses only, once per port, lowest port first.
    static func parse(_ output: String) -> [LocalServer] {
        var found: [Int: String] = [:]
        var process = ""
        for line in output.split(separator: "\n") {
            guard let kind = line.first else { continue }
            let value = String(line.dropFirst())
            if kind == "c" { process = value }
            guard kind == "n", let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]) else { continue }
            let host = value[..<colon]
            guard port >= 1024, ["*", "127.0.0.1", "[::1]", "0.0.0.0", "[::]"].contains(String(host)),
                  isDevelopment(process), found[port] == nil else { continue }
            found[port] = process
        }
        return found.map { LocalServer(port: $0.key, process: $0.value) }.sorted { $0.port < $1.port }
    }

    private static func isDevelopment(_ process: String) -> Bool {
        let name = process.lowercased()
        return processes.contains { name == $0 || name.hasPrefix($0 + "3") || name.hasPrefix($0 + ".") || name.hasPrefix($0 + "-") }
    }

    /// Asks once; nothing keeps watching.
    static func scan() async -> [LocalServer] {
        await Task.detached(priority: .utility) {
            // lsof can hang on an unreachable network volume: the deadline keeps the scan from waiting on it forever.
            guard let result = try? ProcessRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FcnP"], timeout: 10)
            else { return [] }
            return parse(result.stdout)
        }.value
    }
}

/// A Jupyter notebook as markdown, so it reads like any other document.
enum NotebookDocument {
    private static func text(_ value: Any?) -> String {
        if let string = value as? String { return string }
        return (value as? [String])?.joined() ?? ""
    }

    /// Nil when the file is not a notebook.
    static func markdown(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let cells = root["cells"] as? [[String: Any]] else { return nil }
        let language = ((root["metadata"] as? [String: Any])?["language_info"] as? [String: Any])?["name"] as? String ?? ""
        let blocks = cells.compactMap { cell -> String? in
            let source = text(cell["source"]).trimmingCharacters(in: .whitespacesAndNewlines)
            switch cell["cell_type"] as? String {
            case "markdown":
                return source.isEmpty ? nil : source
            case "code":
                var block = source.isEmpty ? "" : "```\(language)\n\(source)\n```"
                let outputs = (cell["outputs"] as? [[String: Any]] ?? []).map(output).filter { !$0.isEmpty }
                for shown in outputs { block += (block.isEmpty ? "" : "\n\n") + "```\n\(shown)\n```" }
                return block.isEmpty ? nil : block
            default:
                return source.isEmpty ? nil : "```\n\(source)\n```"
            }
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func output(_ cell: [String: Any]) -> String {
        if let stream = cell["text"] { return text(stream).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let data = cell["data"] as? [String: Any], let plain = data["text/plain"] {
            return text(plain).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = cell["evalue"] as? String { return error }
        return ""
    }
}
