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

  it("renders tables and code", () => {
    const html = renderMarkdown("| a | b |\n|---|---|\n| 1 | 2 |\n\n```js\nx < 1\n```");
    expect(html).toContain("<th>a</th>");
    expect(html).toContain("<td>2</td>");
    expect(html).toContain('<pre><code data-lang="js">x &lt; 1</code></pre>');
  });

  it("only links http and https", () => {
    expect(renderMarkdown("[x](javascript:alert(1))")).not.toContain("<a");
    expect(renderMarkdown("[site](https://nook.app)")).toContain('<a href="https://nook.app" data-external>site</a>');
  });
});
