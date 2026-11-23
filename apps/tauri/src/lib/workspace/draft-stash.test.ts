import { beforeEach, describe, expect, it } from "vitest";
import { stashKey, stashed } from "./draft-stash";

const store = new Map<string, string>();
beforeEach(() => {
  store.clear();
  (globalThis as unknown as { localStorage: Storage }).localStorage = {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v),
    removeItem: (k: string) => void store.delete(k),
  } as Storage;
});

describe("stashing a draft", () => {
  it("sets a draft aside and brings the newest back", () => {
    expect(stashKey("first")).toBe("");
    expect(stashKey("second")).toBe("");
    expect(stashed()).toEqual(["first", "second"]);
    expect(stashKey("")).toBe("second");
    expect(stashKey("  ")).toBe("first");
    expect(stashKey("")).toBe("");
  });
});
