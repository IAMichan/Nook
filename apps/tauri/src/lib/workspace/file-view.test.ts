import { describe, expect, it } from "vitest";
import { clampedLine, fileKind, lineHtml, opensOnPreview, splitLines } from "./file-view";

describe("file view", () => {
  it("numbers lines like an editor", () => {
    expect(splitLines("a\r\nb\n")).toEqual(["a", "b"]);
    expect(splitLines("")).toEqual([""]);
    expect(splitLines("a\n\nb")).toEqual(["a", "", "b"]);
  });
  it("knows the kind and where it opens", () => {
    expect(fileKind("/x/README.md")).toBe("markdown");
    expect(fileKind("C:\\x\\flow.MMD")).toBe("diagram");
    expect(fileKind("a.svg")).toBe("page");
    expect(fileKind("a.rs")).toBe("code");
    expect(opensOnPreview("markdown", undefined)).toBe(true);
    expect(opensOnPreview("markdown", 4)).toBe(false);
    expect(opensOnPreview("page", undefined)).toBe(false);
  });
  it("keeps the link's line inside the file", () => {
    expect(clampedLine(99, 10)).toBe(10);
    expect(clampedLine(0, 10)).toBeNull();
    expect(clampedLine(undefined, 10)).toBeNull();
    expect(clampedLine(3, 0)).toBeNull();
    expect(clampedLine(3, 10)).toBe(3);
  });
  it("colors known languages and escapes the rest", () => {
    const [a] = lineHtml(["const x = 1 < 2;"], "a.ts");
    expect(a).toContain('class="tok-keyword"');
    expect(a).toContain("&lt;");
    expect(lineHtml(["<b>"], "a.unknownext")).toEqual(["&lt;b&gt;"]);
  });
});
