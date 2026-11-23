import { describe, expect, it } from "vitest";
import type { RunEvent } from "./api";
import { announcementLevel, next, quietUntil, REPLY_LIMIT, snapshot, spoken, type Snapshot } from "./announcements";

const ev = (id: string, kind: RunEvent["kind"], text = id): RunEvent => ({ id, date: "", kind, text });

describe("screen reader announcements", () => {
  it("the first snapshot is a silent baseline", () => {
    const s: Snapshot = { status: "idle", step: null, replies: [{ id: "a", text: "Done", finished: true }] };
    expect(next(null, s, "everything", "Codex").messages).toEqual([]);
  });

  it("reads a reply once it is finished, once", () => {
    const working = next(null, { status: "working", step: "Editing app.ts", replies: [{ id: "a", text: "Hi", finished: false }] }, "replies", "Codex");
    expect(working.messages).toEqual([]);
    const done = next(working.memory, { status: "idle", step: null, replies: [{ id: "a", text: "**All** done", finished: true }] }, "replies", "Codex");
    expect(done.messages).toHaveLength(1);
    expect(done.messages[0]).toContain("Codex");
    expect(done.messages[0]).toContain("All done");
    const again = next(done.memory, { status: "idle", step: null, replies: [{ id: "a", text: "All done", finished: true }] }, "replies", "Codex");
    expect(again.messages).toEqual([]);
  });

  it("a turn that ended before the session was open is history", () => {
    const base = next(null, { status: "idle", step: null, replies: [] }, "replies", "Claude Code");
    const late = next(base.memory, { status: "idle", step: null, replies: [{ id: "old", text: "Old", finished: true }] }, "replies", "Claude Code");
    expect(late.messages).toEqual([]);
  });

  it("says an approval or question once, and steps only for everything", () => {
    const base = next(null, { status: "working", step: "Reading a.ts", replies: [] }, "everything", "Gemini CLI");
    const step = next(base.memory, { status: "working", step: "Editing b.ts", replies: [] }, "everything", "Gemini CLI");
    expect(step.step).toBe("Editing b.ts");
    expect(next(base.memory, { status: "working", step: "Editing b.ts", replies: [] }, "replies", "Gemini CLI").step).toBeNull();
    const ask = next(step.memory, { status: "approval", step: null, replies: [] }, "replies", "Gemini CLI");
    expect(ask.messages).toHaveLength(1);
    expect(next(ask.memory, { status: "approval", step: null, replies: [] }, "replies", "Gemini CLI").messages).toEqual([]);
    expect(next(step.memory, { status: "approval", step: null, replies: [] }, "off", "Gemini CLI").messages).toEqual([]);
  });

  it("reads Markdown as plain words, cut short", () => {
    expect(spoken("# Title\n- [link](http://x) and `code`\n```\nlet x\n```")).not.toMatch(/[#`[\]]|http/);
    expect(spoken("x".repeat(REPLY_LIMIT + 50)).length).toBeLessThan(REPLY_LIMIT + 40);
  });

  it("takes the replies of the latest turn", () => {
    const events = [ev("u1", "user"), ev("a1", "assistant"), ev("u2", "user"), ev("a2", "assistant"), ev("t", "tool"), ev("a3", "assistant")];
    expect(snapshot(events, "working", null).replies).toEqual([
      { id: "a2", text: "a2", finished: true },
      { id: "a3", text: "a3", finished: false },
    ]);
    expect(snapshot(events, "idle", null).replies.every((r) => r.finished)).toBe(true);
  });

  it("levels fall back to replies and steps wait for the reader", () => {
    expect(announcementLevel("everything")).toBe("everything");
    expect(announcementLevel("loud")).toBe("replies");
    expect(quietUntil(0, [])).toBe(2_000);
    expect(quietUntil(0, ["x".repeat(1000)])).toBe(15_000);
  });
});
