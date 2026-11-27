import { describe, expect, it } from "vitest";
import type { InboxState } from "./agent-inbox";
import { describeChange, UNDO_WINDOW_MS, UndoLog } from "./undo-log";

const state = (over: Partial<InboxState> = {}): InboxState => ({ pinned: [], settled: [], snoozed: {}, groupByProject: false, collapsedProjects: [], ...over });

describe("undo-log (UndoLog)", () => {
  it("merges the same kind and restarts its window", () => {
    const log = new UndoLog();
    log.record("settled", ["a"], 0);
    log.record("settled", ["b", "a"], 3_000);
    expect(log.current(3_000)).toMatchObject({ kind: "settled", ids: ["a", "b"] });
    // Five seconds from the last one, not the first.
    expect(log.current(7_000)).not.toBeNull();
    expect(log.current(3_000 + UNDO_WINDOW_MS)).toBeNull();
  });

  it("keeps another kind apart and undoes the newest", () => {
    const log = new UndoLog();
    log.record("settled", ["a"], 0);
    log.record("pinned", ["b"], 1_000);
    expect(log.current(1_000)?.kind).toBe("pinned");
    expect(log.undo(1_500)?.kind).toBe("pinned");
    expect(log.current(1_500)?.kind).toBe("settled");
    expect(log.undo(10_000)).toBeNull();
  });

  it("ignores an empty action", () => {
    const log = new UndoLog();
    log.record("settled", [], 0);
    expect(log.current(0)).toBeNull();
  });

  it("reads what an action did", () => {
    expect(describeChange(state(), state({ settled: ["a", "b"] }), 0)).toEqual({ kind: "settled", ids: ["a", "b"] });
    expect(describeChange(state({ settled: ["a"] }), state(), 0)).toEqual({ kind: "unsettled", ids: ["a"] });
    expect(describeChange(state(), state({ snoozed: { a: 10 } }), 0)).toEqual({ kind: "snoozed", ids: ["a"] });
    expect(describeChange(state(), state({ pinned: ["a"] }), 0)).toEqual({ kind: "pinned", ids: ["a"] });
    expect(describeChange(state({ pinned: ["a"] }), state(), 0)).toEqual({ kind: "unpinned", ids: ["a"] });
    expect(describeChange(state(), state({ collapsedProjects: ["x"] }), 0)).toBeNull();
  });
});
