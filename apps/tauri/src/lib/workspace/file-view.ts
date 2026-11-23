// What the file viewer shows of a file's text (`FileViewing` + `ArtifactKind` on the Mac): its lines as an editor numbers
// them, the syntax-colored HTML of each, and what kind of file it is (a document, a diagram, a page or code).
import { detectSyntaxLanguage, NO_CARRY, tokenizeLine, type SyntaxCarry } from "../syntax";
import { escapeHtml } from "@nook/web-ui/markdown";

export type FileKind = "markdown" | "diagram" | "page" | "code";

/** Files with a preview one click from their code: Markdown reads as a document, a Mermaid file as its picture, HTML and
 *  SVG as the page. */
export function fileKind(path: string): FileKind {
  const ext = (path.split(/[\\/]/).pop() ?? "").split(".").pop()?.toLowerCase() ?? "";
  if (ext === "md" || ext === "markdown" || ext === "mdx") return "markdown";
  if (ext === "mmd" || ext === "mermaid") return "diagram";
  if (ext === "html" || ext === "htm" || ext === "svg") return "page";
  return "code";
}

/** Markdown and diagrams open on their preview unless a link points at a line of the code. */
export const opensOnPreview = (kind: FileKind, line: number | undefined) => (kind === "markdown" || kind === "diagram") && line === undefined;

/** The lines as an editor numbers them: a trailing newline does not start an empty last line, and `\r\n` is one break. */
export function splitLines(text: string): string[] {
  const lines = text.replace(/\r\n/g, "\n").split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

/** The line to show first: the link's line, kept inside the file. */
export function clampedLine(line: number | undefined, count: number): number | null {
  if (!line || count <= 0) return null;
  return Math.min(Math.max(line, 1), count);
}

/** Above this many lines the viewer shows plain text: colored rows by the thousand would make the panel slow. */
export const COLOR_LINES = 6000;

/** The HTML of every line with `<span class="tok-…">` runs, a block comment or multi-line string carried on. */
export function lineHtml(lines: string[], path: string): string[] {
  const language = lines.length > COLOR_LINES ? null : detectSyntaxLanguage(path);
  if (!language) return lines.map(escapeHtml);
  let carry: SyntaxCarry = NO_CARRY;
  return lines.map((line) => {
    const { tokens, carry: next } = tokenizeLine(line, language, carry);
    carry = next;
    let out = "";
    let cursor = 0;
    for (const t of tokens) {
      const start = Math.max(cursor, Math.min(line.length, t.start));
      const end = Math.max(start, Math.min(line.length, t.end));
      if (start > cursor) out += escapeHtml(line.slice(cursor, start));
      if (end > start) out += `<span class="tok-${t.kind}">${escapeHtml(line.slice(start, end))}</span>`;
      cursor = end;
    }
    return out + escapeHtml(line.slice(cursor));
  });
}
