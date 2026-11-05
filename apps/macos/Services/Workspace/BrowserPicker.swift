import Foundation

// Pointing at an element in Nook's browser, and the servers on this Mac the empty browser offers.
// Foundation only, so tests can use it independently.

/// The element you pointed at. Its text comes from the page, so it is data, never an order.
struct PickedElement: Equatable, Sendable {
    var url: String
    var selector: String
    var text: String
}

enum BrowserPickScript {
    /// The most a picked element brings along.
    static let textLimit = 1500

    /// Body for `callAsyncJavaScript`: highlights what the pointer is on and resolves with the element you click, or
    /// null on Escape or `cancel`. Clicks while picking never reach the page.
    static let pick = """
    return await new Promise((resolve) => {
      const box = document.createElement('div');
      box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #7c6cf0;' +
        'background:rgba(124,108,240,.14);border-radius:3px;display:none';
      document.documentElement.appendChild(box);
      let current = null;
      const selector = (element) => {
        if (element.id) return '#' + CSS.escape(element.id);
        const parts = [];
        for (let node = element; node && node.nodeType === 1 && parts.length < 4; node = node.parentElement) {
          if (node.id) { parts.unshift('#' + CSS.escape(node.id)); break; }
          const same = node.parentElement ? [...node.parentElement.children].filter((c) => c.tagName === node.tagName) : [];
          const tag = node.tagName.toLowerCase();
          parts.unshift(same.length > 1 ? tag + ':nth-of-type(' + (same.indexOf(node) + 1) + ')' : tag);
        }
        return parts.join(' > ');
      };
      const move = (event) => {
        current = document.elementFromPoint(event.clientX, event.clientY);
        if (!current) { box.style.display = 'none'; return; }
        const r = current.getBoundingClientRect();
        box.style.display = 'block';
        box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
        box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      };
      const stop = (event) => { event.preventDefault(); event.stopPropagation(); event.stopImmediatePropagation(); };
      const finish = (value) => {
        window.removeEventListener('mousemove', move, true);
        ['mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach((name) => window.removeEventListener(name, stop, true));
        window.removeEventListener('click', click, true);
        window.removeEventListener('keydown', key, true);
        box.remove();
        delete window.__nookCancelPick;
        resolve(value);
      };
      const click = (event) => {
        stop(event);
        if (!current) return finish(null);
        const text = (current.innerText || current.getAttribute('aria-label') || current.getAttribute('alt') || current.outerHTML || '').trim();
        finish({ selector: selector(current), text: text.slice(0, \(textLimit)) });
      };
      const key = (event) => { if (event.key === 'Escape') { stop(event); finish(null); } };
      window.addEventListener('mousemove', move, true);
      ['mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach((name) => window.addEventListener(name, stop, true));
      window.addEventListener('click', click, true);
      window.addEventListener('keydown', key, true);
      window.__nookCancelPick = () => finish(null);
    });
    """

    static let cancel = "if (window.__nookCancelPick) { window.__nookCancelPick(); }"
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-FcnP"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return parse(String(decoding: data, as: UTF8.self))
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
