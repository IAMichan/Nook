import { describe, expect, it } from "vitest";
import { emptyState, filterRows, pin, projectGroups, sections, settle, snooze, type InboxRow } from "./agent-inbox";

const now = 1_000_000;
const row = (id: string, over: Partial<InboxRow> = {}): InboxRow => ({ id, title: id, project: "nook", attention: "idle", lastActivity: now, ...over });
const ids = (list: ReturnType<typeof sections>, kind: string) => list.find((s) => s.kind === kind)?.rows.map((e) => e.row.id) ?? [];

describe("agent inbox layout", () => {
  it("puts every row in exactly one section", () => {
    const rows = [row("a"), row("b", { attention: "working" }), row("c"), row("d"), row("e")];
    let state = pin(emptyState(), "a");
    state = settle(state, "c");
    state = snooze(state, "d", now + 1000);
    const list = sections(rows, state, { showWorking: true, now });
    expect(ids(list, "pinned")).toEqual(["a"]);
    expect(ids(list, "working")).toEqual(["b"]);
    expect(ids(list, "settled")).toEqual(["c"]);
    expect(ids(list, "snoozed")).toEqual(["d"]);
    expect(ids(list, "active")).toEqual(["e"]);
  });

  it("never hides what needs you, settled or snoozed", () => {
    let state = settle(emptyState(), "a");
    state = snooze(state, "b", now + 1000);
    const list = sections([row("a", { attention: "approval" }), row("b", { attention: "input" })], state, { showWorking: true, now });
    expect(ids(list, "active")).toEqual(["a", "b"]);
  });

  it("sorts active by attention, then newest first", () => {
    const list = sections([row("old", { lastActivity: 1 }), row("new", { lastActivity: 5 }), row("ask", { attention: "input", lastActivity: 0 })], emptyState(), { showWorking: false, now });
    expect(ids(list, "active")).toEqual(["ask", "new", "old"]);
  });

  it("pages the settled shelf but keeps the open session", () => {
    const rows = Array.from({ length: 12 }, (_, i) => row(`s${i}`, { lastActivity: 100 - i }));
    const state = { ...emptyState(), settled: rows.map((r) => r.id) };
    const list = sections(rows, state, { showWorking: false, now, selectedId: "s11" });
    const shelf = list.find((s) => s.kind === "settled")!;
    expect(shelf.rows).toHaveLength(11);
    expect(shelf.hiddenCount).toBe(1);
  });

  it("groups working and active rows per project, in a fixed order", () => {
    const rows = [row("a", { project: "zeta" }), row("b", { project: "alpha", attention: "working" }), row("c", { project: "alpha", lastActivity: now + 1 })];
    const groups = projectGroups(sections(rows, emptyState(), { showWorking: true, now }));
    expect(groups.map((g) => g.project)).toEqual(["alpha", "zeta"]);
    expect(groups[0].rows.map((r) => r.entry.row.id)).toEqual(["c", "b"]);
  });

  it("searches title and project by token, ignoring case and accents", () => {
    const rows = [row("Café fix", { project: "Nook" }), row("other", { project: "site" })];
    expect(filterRows(rows, "cafe nook").map((r) => r.id)).toEqual(["Café fix"]);
  });
});
