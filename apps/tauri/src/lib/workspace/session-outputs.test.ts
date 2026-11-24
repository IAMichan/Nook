import { describe, expect, it } from "vitest";
import type { RunEvent } from "./api";
import { collectOutputs, hasNewOutput, isShare, opensByItself, outputKind, outputSignature, resolveOutputPath, sharedPaths, taskList } from "./session-outputs";

let n = 0;
const ev = (e: Partial<RunEvent>, at: number): RunEvent => ({ id: `e${++n}`, date: new Date(at).toISOString(), kind: "tool", text: "", ...e });

describe("session outputs", () => {
  it("knows what is made to be seen", () => {
    expect(outputKind("a/b.HTML")).toBe("design");
    expect(outputKind("C:\\x\\notes.md")).toBe("document");
    expect(outputKind("x.png")).toBe("image");
    expect(outputKind("x.rs")).toBeNull();
  });
  it("resolves a relative name against the folder", () => {
    expect(resolveOutputPath("out/../a.html", "/w/app/")).toBe("/w/app/a.html");
    expect(resolveOutputPath("/abs/a.png", "/w")).toBe("/abs/a.png");
    expect(resolveOutputPath("a.png", null)).toBe("a.png");
  });
  it("collects each file once at its last write, plans, and the task list, newest first", () => {
    const events = [
      ev({ kind: "assistant", tool: "plan", text: "# Ship it\n- a" }, 1000),
      ev({ tool: "Write", detail: JSON.stringify({ file_path: "/w/page.html" }) }, 2000),
      ev({ tool: "Write", detail: JSON.stringify({ file_path: "/w/code.rs" }) }, 2500),
      ev({ tool: "Edit", detail: JSON.stringify({ file_path: "/w/page.html" }) }, 3000),
      ev({ tool: "mcp__x__SendUserFile", detail: JSON.stringify({ files: ["clip.mp4"] }) }, 4000),
      ev({ kind: "fileChange", text: "doc.md", detail: "/w/doc.md" }, 5000),
      ev({ tool: "TodoWrite", detail: JSON.stringify({ todos: [{ content: "A", status: "completed" }, { content: "B", activeForm: "Doing B", status: "in_progress" }] }) }, 6000),
    ];
    const out = collectOutputs(events, null, "/w");
    expect(out.map((o) => o.id)).toEqual(["tasks", "file:/w/doc.md", "file:/w/clip.mp4", "file:/w/page.html", "plan:" + events[0].id]);
    expect(out[0].steps).toEqual([{ text: "A", status: "done" }, { text: "Doing B", status: "active" }]);
    expect(out.find((o) => o.id === "file:/w/clip.mp4")?.shared).toBe(true);
    expect(out.find((o) => o.id === "file:/w/page.html")?.date).toBe(3000);
    expect(out.find((o) => o.kind === "plan")?.title).toBe("Ship it");
  });
  it("keeps the live task list over the last one written", () => {
    const out = collectOutputs([], [{ text: "X", status: "pending" }], "/w");
    expect(out).toHaveLength(1);
    expect(out[0].steps?.[0].text).toBe("X");
  });
  it("reads hand-overs and Codex plans", () => {
    expect(sharedPaths({ file: " a.png " })).toEqual(["a.png"]);
    expect(isShare(ev({ tool: "SendUserFile", state: "failed", detail: '{"file":"a"}' }, 1))).toBe(false);
    expect(isShare(ev({ tool: "image_generation", detail: '{"path":"a.png"}' }, 1))).toBe(true);
    expect(taskList("update_plan", { plan: [{ step: "One", status: "completed" }, { status: "pending" }] })).toEqual([
      { text: "One", status: "done" }, { text: "Step 2", status: "pending" },
    ]);
    expect(taskList("Write", {})).toBeNull();
  });
  it("opens by itself only for what is worth looking at now", () => {
    const o = (kind: "document" | "design" | "tasks", shared = false) => ({ id: "x", kind, title: "", path: "p", date: 10, shared });
    expect(opensByItself(o("design"), 5)).toBe(true);
    expect(opensByItself(o("design"), 20)).toBe(false);
    expect(opensByItself(o("document"), 5)).toBe(false);
    expect(opensByItself(o("document", true), 5)).toBe(true);
    expect(opensByItself(o("tasks"), 5)).toBe(false);
    expect(opensByItself(o("design"), null)).toBe(false);
  });
  it("notices something new", () => {
    const a = { id: "file:a", kind: "image" as const, title: "a", path: "a", date: 1, shared: false };
    expect(hasNewOutput([a], new Set())).toBe(true);
    expect(hasNewOutput([a], new Set([outputSignature(a)]))).toBe(false);
    expect(hasNewOutput([{ ...a, date: 2 }], new Set([outputSignature(a)]))).toBe(true);
  });
});
