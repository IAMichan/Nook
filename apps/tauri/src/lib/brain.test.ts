import { describe, expect, it } from "vitest";
import { outcomeLabel } from "./brain";

describe("outcomeLabel", () => {
  it("beschrijft elke uitkomst van een opzoeking", () => {
    expect(outcomeLabel({ kind: "running" })).toBe("bezig…");
    expect(outcomeLabel({ kind: "found", detail: 3 })).toBe("doorzocht · 3");
    expect(outcomeLabel({ kind: "empty" })).toBe("niets gevonden");
    expect(outcomeLabel({ kind: "failed", detail: "time-out" })).toBe("mislukt: time-out");
  });
});
