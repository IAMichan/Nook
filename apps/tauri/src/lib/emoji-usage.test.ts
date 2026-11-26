import { describe, expect, it } from "vitest";
import { allEmoji, searchEmoji } from "./emoji-catalog";
import {
  EMOJI_KEPT_COUNT,
  EMOJI_SHOWN_COUNT,
  EmojiUsageStore,
  emojiUsageScore,
  type EmojiStorage,
} from "./emoji-usage";

function memoryStorage(): EmojiStorage {
  const data = new Map<string, string>();
  return {
    getItem: (key) => data.get(key) ?? null,
    setItem: (key, value) => {
      data.set(key, value);
    },
  };
}

const START = 1_800_000_000_000;
const days = (count: number) => START + count * 24 * 3600 * 1000;

describe("EmojiUsageStore", () => {
  it("stays empty until something is chosen", () => {
    const usage = new EmojiUsageStore(memoryStorage(), "test.emoji", null);
    expect(usage.ranked(EMOJI_SHOWN_COUNT, START)).toEqual([]);
    const list = ["😀", "😂"];
    expect(usage.usedFirst(list, (c) => c, START)).toEqual(list);
  });

  it("puts most used first and breaks ties by last used", () => {
    const usage = new EmojiUsageStore(memoryStorage(), "test.emoji", null);
    usage.record("😂", START);
    usage.record("😂", START);
    usage.record("👍", START);
    usage.record("🔥", START + 60_000);
    expect(usage.ranked(EMOJI_SHOWN_COUNT, days(0.1))).toEqual(["😂", "🔥", "👍"]);
  });

  it("fades old use so recent use rises", () => {
    const usage = new EmojiUsageStore(memoryStorage(), "test.emoji", null);
    for (let i = 0; i < 4; i++) usage.record("😂", START);
    usage.record("🎉", days(60));
    usage.record("🎉", days(60));
    expect(usage.ranked(EMOJI_SHOWN_COUNT, days(60))).toEqual(["🎉", "😂"]);
    expect(emojiUsageScore({ score: 2, last: START }, days(14))).toBeCloseTo(1, 4);
  });

  it("prunes to keptCount and survives a restart", () => {
    const storage = memoryStorage();
    const usage = new EmojiUsageStore(storage, "test.emoji", null);
    const sample = allEmoji().slice(0, EMOJI_KEPT_COUNT + 10);
    sample.forEach((item, index) => usage.record(item.character, START + index * 1000));
    expect(Object.keys(usage.entries(days(1))).length).toBe(EMOJI_KEPT_COUNT);
    expect(usage.ranked(EMOJI_SHOWN_COUNT, days(1)).length).toBe(EMOJI_SHOWN_COUNT);
    const reloaded = new EmojiUsageStore(storage, "test.emoji", null);
    expect(reloaded.ranked(1, days(1))).toEqual([sample[EMOJI_KEPT_COUNT + 9].character]);
  });

  it("puts used emoji first in search results", () => {
    const usage = new EmojiUsageStore(memoryStorage(), "test.emoji", null);
    usage.record("❤️", START);
    const found = usage.usedFirst(searchEmoji("heart"), (e) => e.character, START);
    expect(found[0]?.character).toBe("❤️");
    expect(found.length).toBeGreaterThan(1);
  });

  it("migrates legacy flat frequency counts", () => {
    const storage = memoryStorage();
    storage.setItem("chats.emoji.frequent", JSON.stringify({ "🔥": 5, "👍": 2 }));
    const usage = new EmojiUsageStore(storage, "test.emoji", "chats.emoji.frequent");
    expect(usage.ranked(EMOJI_SHOWN_COUNT, START)).toEqual(["🔥", "👍"]);
  });
});
