// Answers as Markdown: the shared renderer (packages/web-ui, the browser extension's side panel uses it too) with the
// Copy button in this app's language.
import { escapeHtml, renderMarkdown as render } from "@nook/web-ui/markdown";
import { tr } from "./i18n.svelte";

export { escapeHtml };

export function renderMarkdown(source: string): string {
  return render(source, { copy: tr("Kopieer", "Copy"), copyTitle: tr("Code kopiëren", "Copy code") });
}
