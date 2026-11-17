import { describe, expect, it } from "vitest";
import {
  canRunCode,
  detectSyntaxLanguage,
  highlightCodeToHtml,
  isShellLanguage,
  NO_CARRY,
  shellCommand,
  syntaxForFence,
  tokenizeLine,
} from "./syntax";

describe("syntaxForFence and detectSyntaxLanguage", () => {
  it("recognizes fence languages and filename extensions", () => {
    expect(syntaxForFence("swift", null)).toBe("swift");
    expect(syntaxForFence("tsx", null)).toBe("typescript");
    expect(syntaxForFence("py", null)).toBe("python");
    expect(syntaxForFence("rs", null)).toBe("rust");
    expect(syntaxForFence("zsh", null)).toBe("shell");
    expect(syntaxForFence("", "src/App.tsx")).toBe("typescript");
    expect(syntaxForFence("", ".zshrc")).toBe("shell");
    expect(syntaxForFence("", "Cargo.toml")).toBeNull();
    expect(syntaxForFence("swift", "Main.swift")).toBe("swift");
  });

  it("detects language from filenames across supported extensions", () => {
    expect(detectSyntaxLanguage("config.json")).toBe("json");
    expect(detectSyntaxLanguage("src/main.rs")).toBe("rust");
    expect(detectSyntaxLanguage("View.swift")).toBe("swift");
    expect(detectSyntaxLanguage("script.sh")).toBe("shell");
    expect(detectSyntaxLanguage("app.py")).toBe("python");
    expect(detectSyntaxLanguage("server.go")).toBe("go");
  });
});

describe("tokenizeLine and highlightCodeToHtml", () => {
  it("carries multi-line block comments and template strings across lines", () => {
    const first = tokenizeLine("/* start", "typescript", NO_CARRY);
    expect(first.carry).toEqual({ kind: "blockComment" });
    expect(first.tokens[0]?.kind).toBe("comment");

    const second = tokenizeLine("still comment */ let x = `multi", "typescript", first.carry);
    expect(second.carry).toEqual({ kind: "string", delimiter: "`" });
    expect(second.tokens.map((t) => t.kind)).toContain("keyword");
    expect(second.tokens.map((t) => t.kind)).toContain("string");

    const html = highlightCodeToHtml("/* a\nb */\nconst n = 42", "ts");
    expect(html).toContain('<span class="tok-comment">/* a</span>');
    expect(html).toContain('<span class="tok-comment">b */</span>');
    expect(html).toContain('<span class="tok-keyword">const</span>');
    expect(html).toContain('<span class="tok-number">42</span>');
  });

  it("escapes HTML in code and skips highlighting above 20,000 chars", () => {
    const html = highlightCodeToHtml('const tag = "<b>1</b>"', "js");
    expect(html).toContain("&lt;b&gt;1&lt;/b&gt;");
    expect(html).not.toContain("<b>");

    expect(highlightCodeToHtml("x\n".repeat(12_000), "js")).toBeNull();
  });

  it("highlights YAML, JSON, HTML and CSS", () => {
    const yaml = highlightCodeToHtml("name: Nook\nport: 3000 # local", "yaml");
    expect(yaml).toContain('<span class="tok-property">name</span>');
    expect(yaml).toContain('<span class="tok-number">3000</span>');
    expect(yaml).toContain('<span class="tok-comment"># local</span>');

    const html = highlightCodeToHtml('<div class="box">hi</div>', "html");
    expect(html).toContain('<span class="tok-tag">&lt;div</span>');
    expect(html).toContain('<span class="tok-property">class</span>');

    const css = highlightCodeToHtml(".box { color: #ff00aa; }", "css");
    expect(css).toContain('<span class="tok-property">color</span>');
    expect(css).toContain('<span class="tok-number">#ff00aa</span>');
  });
});

describe("shell execution guards", () => {
  it("strips leading prompts and allows clean shell commands", () => {
    expect(isShellLanguage("zsh")).toBe(true);
    expect(isShellLanguage("python")).toBe(false);
    expect(shellCommand("$ echo hello\n$ pwd")).toBe("echo hello\npwd");
    expect(canRunCode("$ npm test")).toBe(true);
  });

  it("blocks hidden bidi chars, control chars and trailing backslash continuations", () => {
    expect(canRunCode("echo \u202e evil")).toBe(false);
    expect(canRunCode("echo \x07bell")).toBe(false);
    expect(canRunCode("echo \\")).toBe(false);
    expect(canRunCode("   \n# only comments")).toBe(true);
    expect(canRunCode("   \n")).toBe(false);
  });
});
