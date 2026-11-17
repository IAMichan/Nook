import { describe, expect, it } from "vitest";
import { EmojiUsage, allEmoji, emojiFor, emojiGroups, searchEmoji, type EmojiUsageStore } from "./emoji";

function memory(): EmojiUsageStore {
  const map = new Map<string, string>();
  return { getItem: (k) => map.get(k) ?? null, setItem: (k, v) => void map.set(k, v) };
}

const start = 1_800_000_000_000;
const days = (n: number) => start + n * 24 * 3600 * 1000;

describe("emoji catalog", () => {
  it("has Unicode's nine groups in order, smileys first", () => {
    expect(emojiGroups.map((g) => g.key)).toEqual(["smileys", "people", "animals", "food", "travel", "activities", "objects", "symbols", "flags"]);
    expect(emojiGroups[0].emoji[0]).toEqual({ character: "😀", name: "grinning face" });
    expect(allEmoji.length).toBeGreaterThan(1800);
  });

  it("finds an emoji with or without its variation selector, and keeps an unknown one as its own name", () => {
    expect(emojiFor("❤️").name).toBe("red heart");
    expect(emojiFor("❤").name).toBe("red heart");
    expect(emojiFor("👍🏽")).toEqual({ character: "👍🏽", name: "👍🏽" });
  });

  it("searches English names and Nook's own names, word starts first", () => {
    expect(searchEmoji("")).toEqual([]);
    expect(searchEmoji("tears joy")[0].character).toBe("😂");
    expect(searchEmoji("lachen").map((e) => e.character)).toContain("😂");
    expect(searchEmoji("hart").map((e) => e.character)).toContain("❤️");
    const cat = searchEmoji("cat");
    expect(cat[0].name.split(" ").some((w) => w.startsWith("cat"))).toBe(true);
    expect(searchEmoji("zzzzqq")).toEqual([]);
  });
});

describe("EmojiUsage", () => {
  it("is empty until something is chosen", () => {
    const usage = new EmojiUsage(memory());
    expect(usage.ranked(18, start)).toEqual([]);
    expect(usage.usedFirst(["😀", "😂"], (c) => c, start)).toEqual(["😀", "😂"]);
  });

  it("puts the most used first and the last used first on a tie", () => {
    const usage = new EmojiUsage(memory());
    usage.record("😂", start);
    usage.record("😂", start);
    usage.record("👍", start);
    usage.record("🔥", start + 60_000);
    expect(usage.ranked(18, days(0.1))).toEqual(["😂", "🔥", "👍"]);
    expect(usage.usedFirst(["😀", "👍", "😂"], (c) => c, days(0.1))).toEqual(["😂", "👍", "😀"]);
  });

  it("lets old use fade so recent use rises, halving every two weeks", () => {
    const usage = new EmojiUsage(memory());
    for (let i = 0; i < 4; i++) usage.record("😂", start);
    usage.record("🎉", days(60));
    usage.record("🎉", days(60));
    expect(usage.ranked(18, days(60))).toEqual(["🎉", "😂"]);
    expect(EmojiUsage.score({ score: 2, last: start }, days(14))).toBeCloseTo(1, 6);
  });

  it("keeps at most 64", () => {
    const usage = new EmojiUsage(memory());
    allEmoji.slice(0, 70).forEach((e, i) => usage.record(e.character, start + i));
    expect(Object.keys(usage.entries)).toHaveLength(EmojiUsage.keptCount);
    expect(usage.ranked(1, start + 100)).toEqual([allEmoji[69].character]);
  });

  it("survives a broken store", () => {
    const store = memory();
    store.setItem("chatEmojiUsage", "{not json");
    const usage = new EmojiUsage(store);
    expect(usage.ranked()).toEqual([]);
    usage.record("😀", start);
    expect(usage.ranked(18, start)).toEqual(["😀"]);
  });
});
