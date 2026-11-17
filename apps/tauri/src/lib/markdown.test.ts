import { describe, expect, it } from "vitest";
import { renderMarkdown } from "./markdown";

describe("renderMarkdown", () => {
  it("escapes html from the model", () => {
    expect(renderMarkdown("<script>alert(1)</script>")).toBe("<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>");
  });

  it("renders lists, bold and citations", () => {
    expect(renderMarkdown("- **Morgen** om 10 uur [1]\n- Lisa")).toBe(
      '<ul><li><strong>Morgen</strong> om 10 uur <sup class="cite" data-cite="1">1</sup></li><li>Lisa</li></ul>',
    );
  });

  it("renders tables with numeric column alignment and syntax-highlighted code", () => {
    const html = renderMarkdown("| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nx < 1\n```");
    expect(html).toContain('<th class="num">a</th>');
    expect(html).toContain('<td class="num">2</td>');
    expect(html).toContain('<pre><code data-lang="js">x &lt; <span class="tok-number">1</span></code></pre>');
  });

  it("only links http and https and shows hidden host suffix", () => {
    expect(renderMarkdown("[x](javascript:alert(1))")).not.toContain("<a");
    expect(renderMarkdown("[site](https://nook.app)")).toContain(
      '<a href="https://nook.app/" data-external title="https://nook.app/">site</a><span class="link-host"> (nook.app)</span>',
    );
  });

  it("renders callouts, collapsible details, rules and PR pills", () => {
    expect(renderMarkdown("> [!TIP] Handig om te weten")).toContain('class="callout tip"');
    expect(renderMarkdown("<details><summary>Meer</summary>\n\n**Inhoud**\n\n</details>")).toContain(
      '<details class="md-details"><summary>Meer</summary>',
    );
    expect(renderMarkdown("---")).toBe('<hr class="md-rule" />');
    expect(renderMarkdown("<pr-created>https://github.com/IAMichan/Nook/pull/42</pr-created>")).toContain(
      "IAMichan/Nook #42",
    );
  });
});

describe("code blocks", () => {
  it("carry a Copy button next to the escaped and highlighted code", () => {
    const html = renderMarkdown("```sh\nnpm run tauri dev\n```");
    expect(html).toContain("data-copy-code");
    expect(html).toContain('<pre><code data-lang="sh">npm run tauri dev</code></pre>');
  });
});
