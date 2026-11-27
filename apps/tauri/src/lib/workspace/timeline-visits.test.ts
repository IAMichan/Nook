import { describe, expect, it } from "vitest";
import { firstNew, OPEN_LIMIT, parseVisits, remember, VISIT_LIMIT, type Visits } from "./timeline-visits";

describe("timeline-visits (TimelineVisits, TimelineLanding)", () => {
  it("finds the first new row only when something older comes before it", () => {
    const rows = [{ id: "a", date: 10 }, { id: "b", date: null }, { id: "c", date: 30 }, { id: "d", date: 40 }];
    expect(firstNew(rows, 20)).toBe("c");
    expect(firstNew(rows, 5)).toBeNull();
    expect(firstNew(rows, 50)).toBeNull();
  });

  it("keeps the most recently viewed and caps the open folds", () => {
    let visits: Visits = {};
    for (let i = 0; i < VISIT_LIMIT + 3; i++) visits = remember(visits, `s${i}`, { open: [], lastViewedAt: i });
    expect(Object.keys(visits)).toHaveLength(VISIT_LIMIT);
    expect(visits.s0).toBeUndefined();
    expect(visits[`s${VISIT_LIMIT + 2}`]).toBeDefined();
    const many = Array.from({ length: OPEN_LIMIT + 10 }, (_, i) => `fold:${i}`);
    expect(remember({}, "x", { open: many, lastViewedAt: 1 }).x.open).toHaveLength(OPEN_LIMIT);
  });

  it("reads what it can and drops the rest", () => {
    expect(parseVisits("not json")).toEqual({});
    expect(parseVisits(JSON.stringify({ a: { open: ["x", 3], lastViewedAt: 5 }, b: null, c: { open: "x" } }))).toEqual({
      a: { open: ["x"], lastViewedAt: 5 },
      c: { open: [], lastViewedAt: 0 },
    });
  });
});
