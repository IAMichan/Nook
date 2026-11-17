// Answers as Markdown: the shared renderer (packages/web-ui, the browser extension's side panel uses it too) with the
// Copy button in this app's language.
import { escapeHtml, renderMarkdown as render } from "@nook/web-ui/markdown";
import { citationLabel, citationReferences, isOpenableUrl, withoutSourceList } from "./citations";
import { sourceGlyphSvg } from "./service-icons";
import { sourceDomain } from "./sources";
import { tr } from "./i18n.svelte";
import type { SourceReference } from "./types";

export { escapeHtml };

export function renderMarkdown(source: string): string {
  return render(source, { copy: tr("Kopieer", "Copy"), copyTitle: tr("Code kopiëren", "Copy code") });
}

/**
 * Renders a Nook answer: strips any model-written "Sources:" list, and turns `[1]` / `[1, 4]` / `[1][2]`
 * backed by `references` into clickable citation pills labeled by sender or short name. Unbacked numbers
 * stay as raised numbers.
 */
export function renderAnswerMarkdown(source: string, references: SourceReference[]): string {
  const cleaned = withoutSourceList(source);
  const copy = tr("Kopieer", "Copy");
  const copyTitle = tr("Code kopiëren", "Copy code");
  if (!references.length) {
    return render(cleaned, { copy, copyTitle });
  }
  return render(cleaned, {
    copy,
    copyTitle,
    citation: (numbers) => {
      const cited = citationReferences(numbers, references);
      if (!cited.length) {
        return `<sup class="cite" data-cite="${numbers.join(",")}">${numbers.join(", ")}</sup>`;
      }
      const first = cited[0];
      const domain = sourceDomain(first.sourceId);
      const nums = cited.map((r) => r.number).join(",");
      const label = escapeHtml(citationLabel(cited));
      const openAttr = cited.length === 1 && isOpenableUrl(first.url) ? ' data-openable="1"' : "";
      const domainAttr = domain ? ` data-icon-domain="${escapeHtml(domain)}"` : "";
      return `<button type="button" class="cite-pill" data-cites="${nums}"${openAttr}><span class="cite-ico"${domainAttr}>${sourceGlyphSvg(first.sourceId)}</span><span class="cite-label">${label}</span></button>`;
    },
  });
}
