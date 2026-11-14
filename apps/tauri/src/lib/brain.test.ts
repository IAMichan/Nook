import { describe, expect, it } from "vitest";
import { outcomeLabel } from "./brain";

describe("outcomeLabel", () => {
  it("beschrijft elke uitkomst van een opzoeking", () => {
    expect(outcomeLabel({ kind: "running" })).toBe("searching…");
    expect(outcomeLabel({ kind: "found", detail: 3 })).toBe("searched · 3");
    expect(outcomeLabel({ kind: "empty" })).toBe("nothing found");
    expect(outcomeLabel({ kind: "failed", detail: "time-out" })).toBe("failed: time-out");
  });
});
