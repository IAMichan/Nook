import { describe, expect, it } from "vitest";
import {
  bareLinks,
  canPreviewCode,
  codeLink,
  detectCallout,
  isNumericColumn,
  isSafeLink,
  parseDetailsBlock,
  parseFenceInfo,
  parseImageLine,
  parseMarkdownBlocks,
  previewSrcdoc,
  renderInlineMarkdown,
  tableToCsv,
  tableToMarkdown,
} from "./markdown-blocks";

describe("fence info and image lines", () => {
  it("parses fence language and filename attributes", () => {
    expect(parseFenceInfo('ts title="src/App.tsx"')).toEqual({ language: "ts", title: "src/App.tsx" });
    expect(parseFenceInfo("swift file=Package.swift")).toEqual({ language: "swift", title: "Package.swift" });
    expect(parseFenceInfo("src/lib/syntax.ts")).toEqual({ language: "ts", title: "src/lib/syntax.ts" });
    expect(parseFenceInfo("python")).toEqual({ language: "python", title: null });
  });

  it("parses standalone image lines with optional titles", () => {
    expect(parseImageLine('![Diagram](./docs/arch.png "Architecture")')).toEqual({
      alt: "Diagram",
      source: "./docs/arch.png",
    });
    expect(parseImageLine("![](</path/with spaces/pic.webp>)")).toEqual({
      alt: "",
      source: "/path/with spaces/pic.webp",
    });
    expect(parseImageLine("inline ![a](b.png) text")).toBeNull();
  });
});

describe("details blocks and streaming", () => {
  it("parses closed and nested details blocks and tolerates unclosed streaming tags", () => {
    const lines = [
      "<details><summary>Outer</summary>",
      "<details><summary>Inner</summary>",
      "Inside",
      "</details>",
      "</details>",
    ];
    expect(parseDetailsBlock(lines, 0)).toEqual({
      summary: "Outer",
      body: "<details><summary>Inner</summary>\nInside\n</details>",
      next: 5,
    });

    const streaming = parseDetailsBlock(["<details>", "<summary>Logs</summary>", "line 1"], 0);
    expect(streaming).toEqual({
      summary: "Logs",
      body: "line 1",
      next: 3,
    });

    const nestedTags = parseDetailsBlock(["<details><summary><scr<script>ipt>Safe</script></summary>", "ok", "</details>"], 0);
    expect(nestedTags?.summary).toBe("Safe");
  });
});

describe("lists, callouts and PR links", () => {
  it("parses nested, ordered and task lists", () => {
    const blocks = parseMarkdownBlocks("- [x] Done\n  1. Step one\n  - [ ] Subtask");
    expect(blocks).toEqual([
      {
        kind: "list",
        items: [
          { level: 0, number: null, task: true, text: "Done" },
          { level: 1, number: "1.", task: null, text: "Step one" },
          { level: 1, number: null, task: false, text: "Subtask" },
        ],
      },
    ]);
  });

  it("detects GitHub alerts and localized bold callouts", () => {
    expect(detectCallout("[!WARNING] Check disk space\nBefore continuing")).toEqual({
      kind: "warning",
      title: "Warning",
      body: "Check disk space\nBefore continuing",
    });
    expect(detectCallout("**Tip:** Gebruik Shift+Enter")).toEqual({
      kind: "tip",
      title: "Tip",
      body: "Gebruik Shift+Enter",
    });
  });
});

describe("tables", () => {
  it("detects numeric columns and exports Markdown and CSV cleanly", () => {
    const rows = [
      ["Jan", "€ 12,50", "+4%"],
      ["Feb", "€ 8,00", "-"],
    ];
    expect(isNumericColumn(rows, 0)).toBe(false);
    expect(isNumericColumn(rows, 1)).toBe(true);
    expect(isNumericColumn(rows, 2)).toBe(true);

    expect(tableToMarkdown(["Month", "Amount"], [["Jan", "a \\| b"]])).toBe(
      "| Month | Amount |\n| --- | --- |\n| Jan | a \\\\\\| b |",
    );
    expect(tableToCsv(["Item", "Note"], [["**Box**", 'a, "b"']])).toBe('Item,Note\nBox,"a, ""b"""');
  });
});

describe("links and inline formatting", () => {
  it("rejects unsafe links and strips trailing punctuation from bare URLs", () => {
    expect(isSafeLink("javascript:alert(1)")).toBeNull();
    expect(isSafeLink("https://example.com")?.href).toBe("https://example.com/");
    expect(bareLinks("Check https://nook.app/docs_(v1).")).toEqual([
      { start: 6, end: 32, raw: "https://nook.app/docs_(v1)", url: "https://nook.app/docs_(v1)" },
    ]);
    expect(codeLink("localhost:3000/api")?.href).toBe("http://localhost:3000/api");
    expect(codeLink("not a link")).toBeNull();
  });

  it("adds hover title, hidden host suffix, strikethrough and escaped code", () => {
    const html = renderInlineMarkdown("See [docs](https://example.com/a) ~~old~~ `x < y`");
    expect(html).toContain('title="https://example.com/a"');
    expect(html).toContain('<span class="link-host"> (example.com)</span>');
    expect(html).toContain("<del>old</del>");
    expect(html).toContain("<code>x &lt; y</code>");
  });
});

describe("sandboxed code preview", () => {
  it("wraps HTML and SVG fragments with strict CSP", () => {
    expect(canPreviewCode("html")).toBe(true);
    expect(canPreviewCode("svg")).toBe(true);
    expect(canPreviewCode("ts")).toBe(false);

    const svgDoc = previewSrcdoc("svg", '<svg><circle r="10"/></svg>');
    expect(svgDoc).toContain("Content-Security-Policy");
    expect(svgDoc).toContain('<circle r="10"/>');
  });
});
