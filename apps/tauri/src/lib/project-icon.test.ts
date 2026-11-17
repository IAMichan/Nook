import { describe, expect, it } from "vitest";
import { cleanEmoji, cleanMonogram, defaultProjectTint, parseProjectIcon, projectInitials, storedProjectIcon, PROJECT_TINTS } from "./project-icon";

describe("project icons", () => {
  it("reads and writes the Mac's stored strings", () => {
    for (const s of ["emoji:🚀", "monogram:NK:violet", "image:/Users/me/icon.png"]) {
      expect(storedProjectIcon(parseProjectIcon(s)!)).toBe(s);
    }
    expect(parseProjectIcon("monogram:nk")).toEqual({ kind: "monogram", letters: "NK", tint: "mint" });
    expect(parseProjectIcon("monogram:ab:pink")).toEqual({ kind: "monogram", letters: "AB", tint: "mint" });
    expect(parseProjectIcon("image:C:\\icons\\a.png")).toEqual({ kind: "image", path: "C:\\icons\\a.png" });
    expect(parseProjectIcon("image:relative.png")).toBeNull();
    expect(parseProjectIcon("emoji:a")).toBeNull();
    expect(parseProjectIcon("nonsense")).toBeNull();
    expect(parseProjectIcon(null)).toBeNull();
  });

  it("cleans emoji and monograms", () => {
    expect(cleanEmoji(" 👩‍💻 rest")).toBe("👩‍💻");
    expect(cleanEmoji("🇳🇱")).toBe("🇳🇱");
    expect(cleanEmoji("👍🏽!")).toBe("👍🏽");
    expect(cleanEmoji("1")).toBeNull();
    expect(cleanMonogram("n-o-o-k")).toBe("NO");
    expect(cleanMonogram("--")).toBeNull();
  });

  it("takes initials from the folder name", () => {
    expect(projectInitials("nook-website")).toBe("NW");
    expect(projectInitials("Nook")).toBe("NO");
    expect(projectInitials("---")).toBe("?");
  });

  it("picks the same tint as the Mac (FNV-1a)", () => {
    const fnv = (s: string) => { let h = 2166136261; for (const b of new TextEncoder().encode(s)) { h ^= b; h = Math.imul(h, 16777619) >>> 0; } return h; };
    expect(defaultProjectTint("Nook")).toBe(PROJECT_TINTS[fnv("nook") % 6]);
    expect(fnv("")).toBe(2166136261);
    expect(fnv("a")).toBe(0xe40c292c);
    expect(defaultProjectTint("NOOK")).toBe(defaultProjectTint("nook"));
  });
});
