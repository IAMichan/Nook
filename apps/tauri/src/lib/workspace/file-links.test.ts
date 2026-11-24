import { describe, expect, it } from "vitest";
import { fileName, lineLabel, namedFile, normalizePath, parseFileLink, resolveFileTarget } from "./file-links";

describe("file links", () => {
  it("reads positions", () => {
    expect(parseFileLink("src/app.ts:12:3")).toEqual({ path: "src/app.ts", line: 12, column: 3, endLine: undefined });
    expect(parseFileLink("src/app.ts:42-64")).toMatchObject({ path: "src/app.ts", line: 42, endLine: 64 });
    expect(parseFileLink("src/app.ts:64-42")).toMatchObject({ line: 64, endLine: undefined });
    expect(parseFileLink("/a/b.ts#L12")).toMatchObject({ path: "/a/b.ts", line: 12 });
    expect(parseFileLink("/a/b.ts#L42-L64")).toMatchObject({ line: 42, endLine: 64 });
    expect(parseFileLink("file:///a/b%20c.ts")).toMatchObject({ path: "/a/b c.ts" });
    expect(parseFileLink("file:///C:/work/a.ts:7")).toMatchObject({ path: "C:/work/a.ts", line: 7 });
    expect(parseFileLink("C:\\work\\a.ts:7")).toMatchObject({ path: "C:\\work\\a.ts", line: 7 });
  });
  it("leaves web and mail links alone", () => {
    expect(parseFileLink("https://example.com/a.ts")).toBeNull();
    expect(parseFileLink("mailto:a@b.c")).toBeNull();
    expect(parseFileLink("#top")).toBeNull();
    expect(parseFileLink("a.ts:0")).toBeNull();
  });
  it("labels a range", () => {
    expect(lineLabel({ path: "a", line: 42, endLine: 64 })).toBe("L42\u201364");
    expect(lineLabel({ path: "a", line: 5 })).toBe("L5");
    expect(lineLabel({ path: "a" })).toBeNull();
  });
  it("names a file in a code span, not a type or a domain", () => {
    expect(namedFile("banner.png")).not.toBeNull();
    expect(namedFile("src/app.ts:12")).toMatchObject({ line: 12 });
    expect(namedFile("AppModel.shared")).toBeNull();
    expect(namedFile("example.com")).toBeNull();
    expect(namedFile("docs.example.com/guide.io")).toBeNull();
    expect(namedFile("/api/users")).toBeNull();
    expect(namedFile("two words.md")).toBeNull();
  });
  it("resolves against the folder and home", () => {
    expect(resolveFileTarget({ path: "./src/../a.ts", line: 3 }, "/work/app/", "/home/me")).toEqual({ path: "/work/app/a.ts", line: 3 });
    expect(resolveFileTarget({ path: "~/n.txt" }, null, "/home/me")?.path).toBe("/home/me/n.txt");
    expect(resolveFileTarget({ path: "a.ts" }, null)).toBeNull();
    expect(resolveFileTarget({ path: "a.ts" }, "C:\\work")?.path).toBe("C:/work/a.ts");
    expect(normalizePath("C:\\a\\.\\b\\..\\c")).toBe("C:\\a\\c");
    expect(fileName("/a/b/c.txt/")).toBe("c.txt");
  });
});
