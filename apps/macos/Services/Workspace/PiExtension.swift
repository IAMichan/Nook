import Foundation

/// The Pi extension Nook loads into every Pi session it runs (`pi --extension`). Pi has no permission system and no MCP
/// client of its own, so the extension supplies both: a blocking `tool_call` hook that asks Nook (Pi's `confirm` dialog
/// reaches Nook as an approval, see `PiStreamEvent.confirm`) before a tool runs, and Nook's workspace bridge (`nook-mcp`)
/// registered as Pi tools. It reads its settings from the environment of the Pi process.
enum PiExtension {
    static let permissionVariable = "NOOK_PI_PERMISSION"
    static let bridgeVariable = "NOOK_PI_BRIDGE"
    /// Pi's names for the tools that only read, and for the ones that change files.
    static let readOnlyTools = ["read", "grep", "find", "ls"]
    static let fileChangeTools = ["edit", "write"]
    /// Prefix of the bridge's tools in Pi. Nook asks you about a bridge tool's side effects itself.
    static let bridgeToolPrefix = "mcp__nook__"

    /// What the extension is told about the session's rights: "ask", "acceptEdits" or "bypass".
    static func permissionValue(_ policy: PermissionPolicy) -> String {
        switch policy {
        case .ask: return "ask"
        // Pi has no reviewer, so "auto" (offered by no Pi session) behaves as asking.
        case .auto: return "ask"
        case .acceptEdits: return "acceptEdits"
        case .bypass: return "bypass"
        }
    }

    static var fileURL: URL { NookPaths.supportDirectory.appendingPathComponent("nook-pi-extension.ts") }

    /// Writes the extension when it is missing or out of date.
    @discardableResult
    static func install(at url: URL = fileURL) -> Bool {
        let data = Data(source.utf8)
        if let current = try? Data(contentsOf: url), current == data { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static var source: String {
        """
        // Nook's extension for Pi: asks Nook before tools run, and offers Nook's workspace tools. Written by Nook; edits are overwritten.
        import { spawn } from "node:child_process";

        const READ_ONLY = new Set(\(json(readOnlyTools)));
        const FILE_CHANGES = new Set(\(json(fileChangeTools)));
        const BRIDGE_PREFIX = "\(bridgeToolPrefix)";

        function summary(input) {
          try { return JSON.stringify(input, null, 2).slice(0, 4000); } catch { return String(input).slice(0, 4000); }
        }

        function startBridge(script) {
          const child = spawn(script, ["--agent", "pi"], { stdio: ["pipe", "pipe", "ignore"], env: process.env });
          const pending = new Map();
          let buffer = "";
          let next = 1;
          child.stdout.setEncoding("utf8");
          child.stdout.on("data", (chunk) => {
            buffer += chunk;
            let index;
            while ((index = buffer.indexOf("\\n")) >= 0) {
              const line = buffer.slice(0, index).trim();
              buffer = buffer.slice(index + 1);
              if (!line) continue;
              try {
                const message = JSON.parse(line);
                const waiting = pending.get(message.id);
                if (!waiting) continue;
                pending.delete(message.id);
                if (message.error) waiting.reject(new Error(message.error.message || "bridge error"));
                else waiting.resolve(message.result);
              } catch {}
            }
          });
          child.on("exit", () => {
            for (const waiting of pending.values()) waiting.reject(new Error("The Nook bridge closed."));
            pending.clear();
          });
          child.on("error", () => {});
          const request = (method, params) => new Promise((resolve, reject) => {
            const id = next++;
            pending.set(id, { resolve, reject });
            child.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\\n");
          });
          const notify = (method, params) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method, params }) + "\\n");
          return { child, request, notify };
        }

        export default async function (pi) {
          const mode = process.env.\(permissionVariable) || "ask";

          pi.on("tool_call", async (event, ctx) => {
            if (mode === "bypass") return;
            if (READ_ONLY.has(event.toolName) || event.toolName.startsWith(BRIDGE_PREFIX)) return;
            if (mode === "acceptEdits" && FILE_CHANGES.has(event.toolName)) return;
            const approved = await ctx.ui.confirm(`Allow ${event.toolName}?`, summary(event.input), { signal: ctx.signal });
            if (!approved) return { block: true, reason: `${event.toolName} was declined in Nook.` };
          });

          const script = process.env.\(bridgeVariable);
          if (!script) return;
          try {
            const bridge = startBridge(script);
            await bridge.request("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "pi", version: "1" } });
            bridge.notify("notifications/initialized", {});
            const listed = await bridge.request("tools/list", {});
            for (const tool of listed.tools || []) {
              pi.registerTool({
                name: BRIDGE_PREFIX + tool.name,
                label: tool.name,
                description: tool.description || tool.name,
                parameters: tool.inputSchema || { type: "object", properties: {} },
                async execute(_id, params) {
                  const result = await bridge.request("tools/call", { name: tool.name, arguments: params || {} });
                  const content = (result.content || []).filter((part) => part.type === "text" || part.type === "image");
                  if (result.isError) throw new Error(content.map((part) => part.text || "").join("\\n") || "The tool failed.");
                  return { content: content.length ? content : [{ type: "text", text: "" }], details: { tool: tool.name } };
                },
              });
            }
            pi.on("session_shutdown", () => { try { bridge.child.kill(); } catch {} });
          } catch (error) {
            // Without the bridge Pi still works; the permission hook above stays.
          }
        }
        """
    }

    private static func json(_ values: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
