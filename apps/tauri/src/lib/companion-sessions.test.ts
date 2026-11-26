import { describe, expect, it } from "vitest";
import type { SessionDigest, SessionQuestion } from "./companion";
import { HEADER_MENU, menuEntries, phoneShelf, placeSessions, ROW_MENU, sessionShelf, toggleAnswer, validAnswers } from "./companion-sessions";

const session = (id: string, extra: Partial<SessionDigest> = {}): SessionDigest => ({
  id, title: id, agent: "Codex", attention: "idle", folder: "nook", updated: 0, excerpt: "", items: [], ...extra,
});
const question = (id: string, extra: Partial<SessionQuestion> = {}): SessionQuestion => ({
  id, header: "", question: "Which?", options: ["A", "B", "C"], multiSelect: false, allowsOther: false, ...extra,
});

describe("the Agents tab as on the Mac", () => {
  it("keeps every session at work on top on the phone", () => {
    const question = { id: "q", kind: "question", title: "Which?", detail: "", canAllow: false, options: [] } as SessionDigest["items"][number];
    expect(phoneShelf(session("a", { attention: "working", items: [question] }), 10)).toBe("needsYou");
    expect(phoneShelf(session("b", { attention: "working", pinned: true }), 10)).toBe("working");
    expect(phoneShelf(session("c", { attention: "working", settled: true }), 10)).toBe("working");
    expect(phoneShelf(session("d", { attention: "working", snoozedUntil: 20 }), 10)).toBe("working");
    expect(phoneShelf(session("e", { pinned: true }), 10)).toBe("pinned");
    expect(phoneShelf(session("f", { snoozedUntil: 20 }), 10)).toBe("snoozed");
    expect(phoneShelf(session("g", { settled: true }), 10)).toBe("settled");
    expect(phoneShelf(session("h", { attention: "ready" }), 10)).toBe("active");
  });

  it("puts every session on the Mac's shelf", () => {
    const approval = { id: "i", kind: "approval" as const, title: "", detail: "", canAllow: true, options: [] };
    expect(sessionShelf(session("a", { items: [approval], pinned: true }), true, 10)).toBe("needsYou");
    expect(sessionShelf(session("b", { attention: "working", pinned: true }), true, 10)).toBe("pinned");
    expect(sessionShelf(session("c", { settled: true, snoozedUntil: 20 }), true, 10)).toBe("settled");
    expect(sessionShelf(session("d", { snoozedUntil: 20 }), true, 10)).toBe("snoozed");
    expect(sessionShelf(session("e", { snoozedUntil: 5 }), true, 10)).toBe("active");
    expect(sessionShelf(session("f", { attention: "working" }), true, 10)).toBe("working");
    expect(sessionShelf(session("f", { attention: "working" }), false, 10)).toBe("active");
    const shelves = placeSessions([session("x", { updated: 1 }), session("y", { updated: 2 })], true, 10);
    expect(shelves.active.map((s) => s.id)).toEqual(["y", "x"]);
  });

  it("shows the menus in the Mac's order, only what the session offers", () => {
    expect(menuEntries(ROW_MENU, ["archive", "fork", "rename", "pin", "snoozeHour", "delete"])).toEqual([
      ["rename", "pin", "snooze"], ["fork"], ["copy"], ["archive", "delete"],
    ]);
    expect(menuEntries(HEADER_MENU, ["retry", "regenerateTitle", "unsnooze"])).toEqual([
      ["retry"], ["regenerateTitle"], ["snooze", "copy"],
    ]);
    // A computer without the Agents tab still gets Copy.
    expect(menuEntries(ROW_MENU, undefined)).toEqual([["copy"]]);
  });

  it("checks the answers to every question", () => {
    const qs = [question("q1"), question("q2", { multiSelect: true }), question("q3", { allowsOther: true })];
    const good = { q1: ["A"], q2: ["B", "C"], q3: ["mine"] };
    expect(validAnswers(good, qs)).toEqual(good);
    expect(validAnswers({ q1: ["A"], q2: ["B"] }, qs)).toBeNull();
    expect(validAnswers({ q1: ["A", "B"], q2: ["B"], q3: ["x"] }, qs)).toBeNull();
    expect(validAnswers({ q1: ["Z"], q2: ["B"], q3: ["x"] }, qs)).toBeNull();
    expect(toggleAnswer("A", ["B"], false)).toEqual(["A"]);
    expect(toggleAnswer("A", ["B"], true)).toEqual(["B", "A"]);
    expect(toggleAnswer("B", ["B", "A"], true)).toEqual(["A"]);
  });
});
