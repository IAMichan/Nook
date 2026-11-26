import { describe, expect, it } from "vitest";
import { allEmoji, emojiFor, emojiGroups, searchEmoji } from "./emoji-catalog";

describe("emojiCatalog", () => {
  it("holds every Unicode group and each emoji once without skin tones", () => {
    expect(emojiGroups().map((g) => g.id)).toEqual([
      "smileys",
      "people",
      "animals",
      "food",
      "travel",
      "activities",
      "objects",
      "symbols",
      "flags",
    ]);
    const all = allEmoji();
    expect(all.length).toBeGreaterThan(1800);
    expect(new Set(all.map((e) => e.character)).size).toBe(all.length);
    expect(emojiGroups()[0].emoji[0]).toEqual({ character: "😀", name: "grinning face" });
    expect(all.every((e) => e.character.length > 0 && e.name.length > 0)).toBe(true);
    // No skin-tone variants: the picker shows each emoji once.
    const hasSkinTone = all.some((e) =>
      Array.from(e.character).some((ch) => {
        const cp = ch.codePointAt(0) ?? 0;
        return cp >= 0x1f3fb && cp <= 0x1f3ff;
      }),
    );
    expect(hasSkinTone).toBe(false);
  });

  it("searches by every word and by Nook's own multilingual names", () => {
    expect(searchEmoji("tears joy")[0]?.character).toBe("😂");
    expect(searchEmoji("pizza").some((e) => e.character === "🍕")).toBe(true);
    // Nook's own (Dutch) names for an emoji find it too.
    expect(searchEmoji("lachen").some((e) => e.character === "😂")).toBe(true);
    expect(searchEmoji("netherlands").some((e) => e.character === "🇳🇱")).toBe(true);
    expect(searchEmoji("")).toEqual([]);
    expect(searchEmoji("qqqzzz")).toEqual([]);
  });

  it("looks up emoji by character including variation selector fallbacks", () => {
    expect(emojiFor("😂").name).toBe("face with tears of joy");
    expect(emojiFor("❤").character).toBe("❤️");
    expect(emojiFor("👍🏽").name).toBe("👍🏽");
  });
});
