// Answers as Markdown in the Tauri app: Mac-parity blocks (syntax colors, fence filenames, <details>, standalone
// images, callouts, link titles/hosts) built on top of `markdown-blocks` and `syntax`. Everything from the model
// is escaped before rendering; `@nook/web-ui/markdown` remains untouched for the browser extension.
import { escapeHtml } from "@nook/web-ui/markdown";
import { tr } from "./i18n.svelte";
import { parseMarkdownBlocks, renderInlineMarkdown, isNumericColumn, type InlineOptions } from "./markdown-blocks";
import { highlightCodeToHtml } from "./syntax";

export { escapeHtml };

export function renderMarkdown(source: string, inlineOpts: InlineOptions = {}): string {
  const copy = escapeHtml(tr("Kopieer", "Copy"));
  const copyTitle = escapeHtml(tr("Code kopiëren", "Copy code"));
  const detailsLabel = escapeHtml(tr("Details", "Details"));
  const blocks = parseMarkdownBlocks(source);

  return blocks
    .map((block) => {
      switch (block.kind) {
        case "heading": {
          const level = Math.min(block.level + 2, 6);
          return `<h${level}>${renderInlineMarkdown(block.text, inlineOpts)}</h${level}>`;
        }
        case "paragraph":
          return `<p>${renderInlineMarkdown(block.text, inlineOpts)}</p>`;
        case "list": {
          const ordered = block.items.length > 0 && block.items.every((it) => it.number !== null);
          const tag = ordered ? "ol" : "ul";
          const items = block.items.map((it) => `<li>${renderInlineMarkdown(it.text, inlineOpts)}</li>`).join("");
          return `<${tag}>${items}</${tag}>`;
        }
        case "code": {
          const highlighted = highlightCodeToHtml(block.code, block.language, block.title);
          const body = highlighted ?? escapeHtml(block.code);
          const langAttr = block.language ? ` data-lang="${escapeHtml(block.language)}"` : "";
          const titleAttr = block.title ? ` data-title="${escapeHtml(block.title)}"` : "";
          return `<div class="code-block"><button type="button" class="copy-code" data-copy-code title="${copyTitle}">${copy}</button><pre><code${langAttr}${titleAttr}>${body}</code></pre></div>`;
        }
        case "mermaid":
          return `<div class="code-block"><button type="button" class="copy-code" data-copy-code title="${copyTitle}">${copy}</button><pre><code data-lang="mermaid">${escapeHtml(block.code)}</code></pre></div>`;
        case "math":
          return `<div class="code-block"><button type="button" class="copy-code" data-copy-code title="${copyTitle}">${copy}</button><pre><code data-lang="math">${escapeHtml(block.tex)}</code></pre></div>`;
        case "details": {
          const summary = block.summary ? renderInlineMarkdown(block.summary, inlineOpts) : detailsLabel;
          const inner = block.body ? renderMarkdown(block.body, inlineOpts) : "";
          return `<details class="md-details"><summary>${summary}</summary><div class="md-details-body">${inner}</div></details>`;
        }
        case "image":
          return `<figure class="md-image"><img src="${escapeHtml(block.source)}" alt="${escapeHtml(block.alt)}" title="${escapeHtml(block.alt || block.source)}" /></figure>`;
        case "table": {
          const numeric = block.header.map((_, c) => isNumericColumn(block.rows, c));
          const head = block.header
            .map((c, idx) => `<th${numeric[idx] ? ' class="num"' : ""}>${renderInlineMarkdown(c, inlineOpts)}</th>`)
            .join("");
          const body = block.rows
            .map(
              (r) =>
                `<tr>${r.map((c, idx) => `<td${numeric[idx] ? ' class="num"' : ""}>${renderInlineMarkdown(c, inlineOpts)}</td>`).join("")}</tr>`,
            )
            .join("");
          return `<table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table>`;
        }
        case "quote":
          if (block.callout) {
            return `<blockquote class="callout ${block.callout.kind}"><strong>${escapeHtml(block.callout.title)}</strong>${block.callout.body ? ` ${renderInlineMarkdown(block.callout.body, inlineOpts)}` : ""}</blockquote>`;
          }
          return `<blockquote>${renderInlineMarkdown(block.text, inlineOpts)}</blockquote>`;
        case "rule":
          return `<hr class="md-rule" />`;
        case "pullRequest":
          return `<p><a href="${escapeHtml(block.url)}" data-external title="${escapeHtml(block.url)}">${escapeHtml(`${block.repo} #${block.number}`)}</a></p>`;
      }
    })
    .join("");
}
