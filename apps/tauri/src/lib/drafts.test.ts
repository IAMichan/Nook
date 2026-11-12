import { describe, expect, it } from "vitest";
import { Drafts, MAX_DRAFTS } from "./drafts";

function memory() {
  const data = new Map<string, string>();
  return { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => void data.set(k, v) };
}

describe("drafts", () => {
  it("keep a half written question per Nook", () => {
    const drafts = new Drafts(memory());
    drafts.set("a", "Plan my week");
    drafts.set("b", "Mail Lisa");
    expect(drafts.get("a")).toBe("Plan my week");
    expect(drafts.get("b")).toBe("Mail Lisa");
    expect(drafts.get(null)).toBe("");
    drafts.clear("a");
    expect(drafts.get("a")).toBe("");
  });

  it("drop blank drafts and the oldest beyond the limit", () => {
    const drafts = new Drafts(memory());
    drafts.set("a", "   ");
    expect(drafts.get("a")).toBe("");
    for (let i = 0; i <= MAX_DRAFTS; i++) drafts.set(`n${i}`, `text ${i}`, i);
    expect(drafts.get("n0")).toBe("");
    expect(drafts.get(`n${MAX_DRAFTS}`)).toBe(`text ${MAX_DRAFTS}`);
  });

  it("survive broken or missing storage", () => {
    const broken = { getItem: () => "{not json", setItem: () => { throw new Error("full"); } };
    const drafts = new Drafts(broken);
    expect(drafts.get("a")).toBe("");
    expect(() => drafts.set("a", "x")).not.toThrow();
    expect(new Drafts(null).get("a")).toBe("");
  });
});
