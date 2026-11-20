// Markdown styled as you type (the Mac's rich composer, `richComposer`): the text cut into runs with the styles to draw
// them in. The composer draws these runs in a layer under its field, character for character, so the field stays a
// plain textarea and what is sent stays plain Markdown. Every run keeps its characters: nothing is added or removed, so
// the caret and the selection line up with what is drawn.

export type RichStyle = "marker" | "bold" | "italic" | "strike" | "code" | "codeBlock" | "heading" | "list" | "quote" | "link";

export interface RichRun {
  text: string;
  styles: RichStyle[];
}

/** Inline Markdown in one line: `code`, **bold**, __bold__, *italic*, _italic_, ~~strike~~, [link](url). */
function inline(line: string, base: RichStyle[]): RichRun[] {
  const out: RichRun[] = [];
  const pattern = /(`+)([^`]+?)\1|(\*\*|__)(?=\S)(.+?)(?<=\S)\3|(\*|_)(?=\S)(.+?)(?<=\S)\5(?![*_\w])|(~~)(?=\S)(.+?)(?<=\S)~~|\[([^\]\n]+)\]\(([^)\s]+)\)/g;
  let at = 0;
  const push = (text: string, styles: RichStyle[]) => { if (text) out.push({ text, styles }); };
  for (const m of line.matchAll(pattern)) {
    const start = m.index;
    push(line.slice(at, start), base);
    if (m[1]) {
      push(m[1], [...base, "code", "marker"]);
      push(m[2], [...base, "code"]);
      push(m[1], [...base, "code", "marker"]);
    } else if (m[3]) {
      push(m[3], [...base, "bold", "marker"]);
      for (const run of inline(m[4], [...base, "bold"])) out.push(run);
      push(m[3], [...base, "bold", "marker"]);
    } else if (m[5]) {
      push(m[5], [...base, "italic", "marker"]);
      for (const run of inline(m[6], [...base, "italic"])) out.push(run);
      push(m[5], [...base, "italic", "marker"]);
    } else if (m[7]) {
      push("~~", [...base, "strike", "marker"]);
      push(m[8], [...base, "strike"]);
      push("~~", [...base, "strike", "marker"]);
    } else {
      push("[", [...base, "link", "marker"]);
      push(m[9], [...base, "link"]);
      push(`](${m[10]})`, [...base, "link", "marker"]);
    }
    at = start + m[0].length;
  }
  push(line.slice(at), base);
  return out;
}

/** The whole text as runs, line by line: headings, list items, quotes and fenced code blocks, then inline styles. */
export function richRuns(text: string): RichRun[] {
  const out: RichRun[] = [];
  let fence: string | null = null;
  const lines = text.split("\n");
  lines.forEach((line, i) => {
    const end = i < lines.length - 1 ? "\n" : "";
    const fenceMark = /^\s*(```+|~~~+)/.exec(line);
    if (fence !== null || fenceMark) {
      const open: string | null = fence;
      if (open === null) fence = fenceMark![1];
      else if (fenceMark && fenceMark[1].startsWith(open[0]) && fenceMark[1].length >= open.length) fence = null;
      out.push({ text: line + end, styles: fenceMark ? ["codeBlock", "marker"] : ["codeBlock"] });
      return;
    }
    const heading = /^(#{1,6} )(.*)$/.exec(line);
    const list = /^(\s*(?:[-*+]|\d+[.)]) (?:\[[ xX]\] )?)(.*)$/.exec(line);
    const quote = /^(\s*> ?)(.*)$/.exec(line);
    if (heading) {
      out.push({ text: heading[1], styles: ["heading", "marker"] });
      out.push(...inline(heading[2], ["heading"]));
    } else if (list) {
      out.push({ text: list[1], styles: ["list", "marker"] });
      out.push(...inline(list[2], []));
    } else if (quote) {
      out.push({ text: quote[1], styles: ["quote", "marker"] });
      out.push(...inline(quote[2], ["quote"]));
    } else {
      out.push(...inline(line, []));
    }
    if (end) out.push({ text: end, styles: [] });
  });
  return out;
}

/** Whether the text has any Markdown worth drawing differently: plain text skips the layer. */
export function hasMarkdown(text: string): boolean {
  return richRuns(text).some((run) => run.styles.length > 0);
}
