import { describe, expect, it } from "vitest";
import { fileKind, orderedFiles, orderedPaths, testSubject } from "./pr-file-order";

describe("pr-file-order (PullRequestFileOrder)", () => {
  it("sorts files into kinds", () => {
    expect(fileKind("src/app.ts")).toBe("source");
    expect(fileKind("src/app.test.ts")).toBe("test");
    expect(fileKind("Tests/NookTests/AppModelTests.swift")).toBe("test");
    expect(fileKind("README.md")).toBe("docs");
    expect(fileKind("docs/guide.html")).toBe("docs");
    expect(fileKind("package-lock.json")).toBe("generated");
    expect(fileKind("apps/tauri/Cargo.lock")).toBe("generated");
    expect(fileKind("dist/bundle.js")).toBe("generated");
    expect(fileKind("web/app.min.js")).toBe("generated");
    expect(fileKind("src/__snapshots__/view.snap")).toBe("generated");
  });

  it("names what a test is about", () => {
    expect(testSubject("AppModelTests.swift")).toBe("appmodel");
    expect(testSubject("parser.test.ts")).toBe("parser");
    expect(testSubject("test_util.py")).toBe("util");
  });

  it("puts each source before its tests, then tests, docs and generated files", () => {
    const order = orderedPaths([
      "package-lock.json",
      "README.md",
      "src/parser.test.ts",
      "src/zeta.ts",
      "src/orphan.test.ts",
      "src/parser.ts",
    ]);
    expect(order).toEqual([
      "src/parser.ts",
      "src/parser.test.ts",
      "src/zeta.ts",
      "src/orphan.test.ts",
      "README.md",
      "package-lock.json",
    ]);
  });

  it("keeps the file objects", () => {
    const files = [{ path: "b.md", n: 1 }, { path: "a.ts", n: 2 }];
    expect(orderedFiles(files).map((f) => f.n)).toEqual([2, 1]);
  });
});
