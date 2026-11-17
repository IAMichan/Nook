// Block & inline Markdown parser and helpers (`MarkdownBlock`, `Callout`, `TableText`, `CodeRender` on the Mac).
// Everything is HTML-escaped before leaving this module; model HTML never reaches the page directly except the
// `<details>` blocks parsed explicitly below, and HTML/SVG code previews run in a sandboxed iframe.

import { escapeHtml } from "@nook/web-ui/markdown";

export interface MarkdownListItem {
  level: number;
  number: string | null;
  text: string;
  task: boolean | null;
}

export interface Callout {
  kind: "note" | "tip" | "warning" | "danger";
  title: string;
  body: string;
}

export type MarkdownBlock =
  | { kind: "heading"; level: number; text: string }
  | { kind: "paragraph"; text: string }
  | { kind: "list"; items: MarkdownListItem[] }
  | { kind: "code"; language: string; code: string; title: string | null }
  | { kind: "mermaid"; code: string }
  | { kind: "math"; tex: string }
  | { kind: "details"; summary: string; body: string }
  | { kind: "image"; alt: string; source: string }
  | { kind: "quote"; text: string; callout: Callout | null }
  | { kind: "table"; header: string[]; rows: string[][] }
  | { kind: "rule" }
  | { kind: "pullRequest"; url: string; repo: string; number: number };

const BR_RE = /<br\s*\/?>/gi;
const HEADING_RE = /^#{1,6}\s/;
const RULE_RE = /^([-*_]\s*){3,}$/;
const TABLE_DIVIDER_RE = /^\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?$/;
const BULLET_RE = /^\s*[-*•◦▪+]\s+/;
const NUMBER_RE = /^\s*\d{1,3}[.)]\s+/;
const STRAY_BULLET_RE = /^[•◦▪]\s+/;
const AGENT_TAG_RE = /<([a-z][a-z0-9]*(?:[-_][a-z0-9]+)+)>\s*([^<]*?)\s*<\/\1>/g;
const FENCE_TITLE_RE = /(?:^|\s)(?:title|file(?:name)?)=(?:"([^"]+)"|'([^']+)'|(\S+))/i;
const FENCE_FILE_RE = /^[\w@][\w@./-]*\.[A-Za-z0-9]+$/;
const IMAGE_LINE_RE = /^!\[([^\]]*)\]\(\s*(?:<([^>\n]+)>|([^)\s>]+))(?:\s+"[^"]*")?\s*\)$/;
const DETAILS_OPEN_RE = /^\s*<details[^>]*>/i;
const SUMMARY_OPEN_RE = /^\s*<summary[^>]*>/i;
const SUMMARY_CLOSE_RE = /<\/summary>/i;

/** Normalizes CRLF, `<br>` tags, and stray trailing single backslashes from model output. */
export function cleanMarkdown(text: string): string {
  let normalized = text.includes("\r") ? text.replace(/\r\n/g, "\n").replace(/\r/g, "\n") : text;
  if (normalized.includes("<")) normalized = normalized.replace(BR_RE, "\n");
  if (!normalized.includes("\\")) return normalized;
  return normalized
    .split("\n")
    .map((line) => {
      const trimmed = line.trim();
      if (trimmed === "\\" || trimmed === "\\\\") return "";
      if (line.endsWith("\\") && !line.endsWith("\\\\")) return line.slice(0, -1);
      return line;
    })
    .join("\n");
}

/** Whether a URL uses a safe external scheme (`https`, `http` with host & no userinfo, or `mailto`). */
export function isSafeLink(raw: string): URL | null {
  try {
    const parsed = new URL(raw);
    const scheme = parsed.protocol.toLowerCase();
    if (scheme === "https:" || scheme === "http:") {
      if (!parsed.hostname || parsed.username || parsed.password) return null;
      return parsed;
    }
    if (scheme === "mailto:") return parsed;
    return null;
  } catch {
    return null;
  }
}

/** `owner/repo` and number from a GitHub pull request or GitLab merge request URL. */
export function pullRequestReference(raw: string): { repo: string; number: number } | null {
  const url = isSafeLink(raw);
  if (!url) return null;
  const scheme = url.protocol.toLowerCase();
  if (scheme !== "https:" && scheme !== "http:") return null;
  const parts = url.pathname.split("/").filter(Boolean);
  const at = parts.findIndex((p) => p === "pull" || p === "merge_requests");
  if (at < 2 || at + 1 >= parts.length) return null;
  const number = Number.parseInt(parts[at + 1], 10);
  if (!Number.isFinite(number) || String(number) !== parts[at + 1]) return null;
  const repo = parts
    .slice(0, at)
    .filter((p) => p !== "-")
    .join("/");
  return repo ? { repo, number } : null;
}

/** A standalone agent tag holding a pull request URL (`<pr-created>https://…</pr-created>`). */
export function pullRequestLine(line: string): { url: string; repo: string; number: number } | null {
  if (!line.startsWith("<") || !line.endsWith(">")) return null;
  const m = /^<([a-z][a-z0-9]*(?:[-_][a-z0-9]+)+)>\s*([^<]*?)\s*<\/\1>$/.exec(line);
  if (!m) return null;
  const ref = pullRequestReference(m[2]);
  if (!ref) return null;
  return { url: m[2], ...ref };
}

/** Strips agent tags (`<tag-name>…</tag-name>`) outside code blocks, turning bare URLs inside into `<url>`. */
export function untagLine(line: string): string {
  if (!line.includes("</")) return line;
  return line.replace(AGENT_TAG_RE, (_m, _tag, inner: string) =>
    inner.startsWith("http://") || inner.startsWith("https://") ? `<${inner}>` : inner,
  );
}

/** Language and optional filename in a code fence (`ts title="a.ts"` -> `{ language: "ts", title: "a.ts" }`). */
export function parseFenceInfo(info: string): { language: string; title: string | null } {
  const words = info.trim().split(/\s+/).filter(Boolean);
  if (!words.length) return { language: "", title: null };
  const first = words[0];
  let title: string | null = null;
  const m = FENCE_TITLE_RE.exec(info);
  if (m) title = m[1] ?? m[2] ?? m[3] ?? null;
  if (!title) title = words.find((w) => FENCE_FILE_RE.test(w) && !w.includes("=")) ?? null;
  if (FENCE_FILE_RE.test(first) && !first.includes("=")) {
    const ext = first.slice(first.lastIndexOf(".") + 1).toLowerCase();
    return { language: ext, title };
  }
  return { language: first.includes("=") ? "" : first.toLowerCase(), title };
}

/** Alt text and source of a standalone `![alt](src)` image line. */
export function parseImageLine(line: string): { alt: string; source: string } | null {
  if (!line.startsWith("![")) return null;
  const m = IMAGE_LINE_RE.exec(line);
  if (!m) return null;
  const alt = m[1];
  const src = (m[2] ?? m[3] ?? "").trim();
  if (!src) return null;
  const lower = src.toLowerCase();
  const allowed =
    lower.startsWith("https://") ||
    lower.startsWith("http://") ||
    lower.startsWith("file://") ||
    src.startsWith("/") ||
    src.startsWith("~/") ||
    src.startsWith("./") ||
    src.startsWith("../") ||
    /^[a-zA-Z]:[\\/]/.test(src) ||
    !src.includes(":");
  return allowed ? { alt, source: src } : null;
}

/** Parses a `<details><summary>…</summary>…</details>` block from `index`, handling nested `<details>` and streaming. */
export function parseDetailsBlock(lines: string[], index: number): { summary: string; body: string; next: number } | null {
  const first = lines[index]?.trim() ?? "";
  if (!first.toLowerCase().startsWith("<details")) return null;
  let depth = 0;
  const collected: string[] = [];
  let end = index;
  while (end < lines.length) {
    const lower = lines[end].toLowerCase();
    depth += lower.split("<details").length - 1;
    depth -= lower.split("</details>").length - 1;
    collected.push(lines[end]);
    end += 1;
    if (depth <= 0) break;
  }
  let text = collected.join("\n").replace(DETAILS_OPEN_RE, "");
  if (depth <= 0) {
    const closeAt = text.toLowerCase().lastIndexOf("</details>");
    if (closeAt >= 0) text = text.slice(0, closeAt) + text.slice(closeAt + "</details>".length);
  }
  let summary = "";
  const sOpen = SUMMARY_OPEN_RE.exec(text);
  if (sOpen) {
    const afterOpen = text.slice(sOpen.index + sOpen[0].length);
    const sClose = SUMMARY_CLOSE_RE.exec(afterOpen);
    if (sClose) {
      summary = afterOpen.slice(0, sClose.index);
      text = afterOpen.slice(sClose.index + sClose[0].length);
    }
  }
  summary = summary.replace(/<\/?[a-zA-Z][^>]*>/g, "").trim();
  return { summary, body: text.trim(), next: end };
}

function indentColumns(line: string): number {
  let cols = 0;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (ch === " ") cols += 1;
    else if (ch === "\t") cols += 4;
    else break;
  }
  return cols;
}

function listMarker(line: string): { indent: number; number: string | null; text: string } | null {
  let number: string | null = null;
  let rest = "";
  if (BULLET_RE.test(line)) {
    rest = line.replace(BULLET_RE, "");
  } else if (NUMBER_RE.test(line)) {
    const trimmed = line.trimStart();
    const digits = /^\d+/.exec(trimmed)?.[0] ?? "1";
    number = `${digits}.`;
    rest = line.replace(NUMBER_RE, "");
  } else {
    return null;
  }
  return { indent: indentColumns(line), number, text: rest.replace(STRAY_BULLET_RE, "") };
}

function parseTaskMarker(text: string): { done: boolean | null; text: string } {
  if (text.startsWith("[ ] ")) return { done: false, text: text.slice(4) };
  if (text.startsWith("[x] ") || text.startsWith("[X] ")) return { done: true, text: text.slice(4) };
  return { done: null, text };
}

function parseList(lines: string[], state: { index: number }): MarkdownListItem[] {
  const items: MarkdownListItem[] = [];
  const levels: number[] = [];
  while (state.index < lines.length) {
    const line = lines[state.index];
    const marker = listMarker(line);
    if (marker) {
      while (levels.length && marker.indent < levels[levels.length - 1]) levels.pop();
      if (!levels.length || marker.indent > levels[levels.length - 1]) levels.push(marker.indent);
      const task = parseTaskMarker(marker.text);
      items.push({ level: levels.length - 1, number: marker.number, text: task.text, task: task.done });
    } else if (!line.trim()) {
      if (state.index + 1 < lines.length && listMarker(lines[state.index + 1])) {
        // loose list
      } else {
        break;
      }
    } else if (indentColumns(line) >= 2 && items.length) {
      items[items.length - 1].text += ` ${line.trim()}`;
    } else {
      break;
    }
    state.index += 1;
  }
  return items;
}

function displayMath(lines: string[], index: number): { tex: string; next: number } | null {
  const first = lines[index]?.trim() ?? "";
  let close: string;
  let body: string;
  if (first.startsWith("$$")) {
    close = "$$";
    body = first.slice(2);
  } else if (first.startsWith("\\[")) {
    close = "\\]";
    body = first.slice(2);
  } else {
    return null;
  }
  let end = index;
  while (true) {
    const pos = body.indexOf(close);
    if (pos >= 0) {
      if (body.slice(pos + close.length).trim()) return null;
      const tex = body.slice(0, pos).trim();
      return tex ? { tex, next: end + 1 } : null;
    }
    end += 1;
    if (end >= lines.length || end - index > 200) return null;
    body += `\n${lines[end]}`;
  }
}

const CALLOUT_KEYS: [string, Callout["kind"], string][] = [
  ["note", "note", "Note"],
  ["info", "note", "Info"],
  ["tip", "tip", "Tip"],
  ["important", "warning", "Important"],
  ["warning", "warning", "Warning"],
  ["let op", "warning", "Let op"],
  ["waarschuwing", "warning", "Waarschuwing"],
  ["caution", "danger", "Caution"],
  ["danger", "danger", "Danger"],
  ["opmerking", "note", "Opmerking"],
];

export function detectCallout(text: string): Callout | null {
  const lines = text.split("\n");
  const first = lines[0]?.trim() ?? "";
  if (!first) return null;
  const rest = lines.slice(1).join("\n").trim();
  const lower = first.toLowerCase();
  for (const [key, kind, title] of CALLOUT_KEYS) {
    if (lower.startsWith(`[!${key}]`)) {
      const after = first.slice(key.length + 3).trim();
      return { kind, title, body: [after, rest].filter(Boolean).join("\n") };
    }
    for (const prefix of [`**${key}:**`, `**${key}**:`, `**${key}**`]) {
      if (lower.startsWith(prefix)) {
        const after = first.slice(prefix.length).trim();
        return { kind, title, body: [after, rest].filter(Boolean).join("\n") };
      }
    }
  }
  return null;
}

function tableCells(line: string): string[] {
  let trimmed = line.trim();
  if (trimmed.startsWith("|")) trimmed = trimmed.slice(1);
  if (trimmed.endsWith("|")) trimmed = trimmed.slice(0, -1);
  return trimmed.split("|").map((c) => c.trim());
}

/** Parses Markdown text into blocks, matching the macOS `MarkdownBlock.parse` pipeline. */
export function parseMarkdownBlocks(raw: string): MarkdownBlock[] {
  let inCode = false;
  const lines = cleanMarkdown(raw)
    .split("\n")
    .map((line) => {
      const trimmed = line.trim();
      if (trimmed.startsWith("```")) inCode = !inCode;
      return inCode || trimmed.startsWith("```") || pullRequestLine(trimmed) ? line : untagLine(line);
    });

  const blocks: MarkdownBlock[] = [];
  let paragraph: string[] = [];
  const flush = () => {
    const text = paragraph.join("\n").trim();
    if (text) blocks.push({ kind: "paragraph", text });
    paragraph = [];
  };

  let index = 0;
  while (index < lines.length) {
    const line = lines[index];
    const trimmed = line.trim();

    if (!trimmed) {
      flush();
      index += 1;
      continue;
    }

    if (trimmed.startsWith("```")) {
      flush();
      const { language, title } = parseFenceInfo(trimmed.slice(3));
      const codeLines: string[] = [];
      index += 1;
      while (index < lines.length && !lines[index].trim().startsWith("```")) {
        codeLines.push(lines[index]);
        index += 1;
      }
      index += 1;
      const body = codeLines.join("\n");
      if (language === "math") {
        blocks.push({ kind: "math", tex: body.trim() });
      } else if (language === "mermaid") {
        blocks.push({ kind: "mermaid", code: body });
      } else {
        blocks.push({ kind: "code", language, code: body, title });
      }
      continue;
    }

    const details = parseDetailsBlock(lines, index);
    if (details) {
      flush();
      blocks.push({ kind: "details", summary: details.summary, body: details.body });
      index = details.next;
      continue;
    }

    const img = parseImageLine(trimmed);
    if (img) {
      flush();
      blocks.push({ kind: "image", alt: img.alt, source: img.source });
      index += 1;
      continue;
    }

    const math = displayMath(lines, index);
    if (math) {
      flush();
      blocks.push({ kind: "math", tex: math.tex });
      index = math.next;
      continue;
    }

    if (HEADING_RE.test(trimmed)) {
      flush();
      const hashes = /^#{1,6}/.exec(trimmed)?.[0].length ?? 1;
      blocks.push({ kind: "heading", level: hashes, text: trimmed.slice(hashes).trim() });
      index += 1;
      continue;
    }

    if (RULE_RE.test(trimmed)) {
      flush();
      blocks.push({ kind: "rule" });
      index += 1;
      continue;
    }

    if (trimmed.includes("|") && index + 1 < lines.length && TABLE_DIVIDER_RE.test(lines[index + 1].trim())) {
      flush();
      const header = tableCells(trimmed);
      const rows: string[][] = [];
      index += 2;
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
        const row = tableCells(lines[index]);
        while (row.length < header.length) row.push("");
        rows.push(row.slice(0, header.length));
        index += 1;
      }
      blocks.push({ kind: "table", header, rows });
      continue;
    }

    if (listMarker(line)) {
      flush();
      const state = { index };
      const items = parseList(lines, state);
      blocks.push({ kind: "list", items });
      index = state.index;
      continue;
    }

    if (trimmed.startsWith(">")) {
      flush();
      const quoteLines: string[] = [];
      while (index < lines.length && lines[index].trim().startsWith(">")) {
        quoteLines.push(lines[index].trim().slice(1).trim());
        index += 1;
      }
      const text = quoteLines.join("\n");
      blocks.push({ kind: "quote", text, callout: detectCallout(text) });
      continue;
    }

    const pr = pullRequestLine(trimmed);
    if (pr) {
      flush();
      blocks.push({ kind: "pullRequest", ...pr });
      index += 1;
      continue;
    }

    paragraph.push(line);
    index += 1;
  }
  flush();
  return blocks;
}

// --- Inline rendering ---

const LOCAL_HOSTS = ["localhost", "127.0.0.1", "0.0.0.0", "[::1]"];

/** Turns a local or HTTP(S) code span (`localhost:3000`, `http://localhost:8080/`) into a safe URL. */
export function codeLink(code: string): URL | null {
  const text = code.trim();
  if (!text || /\s/.test(text)) return null;
  const lower = text.toLowerCase();
  const isLocal = LOCAL_HOSTS.some((h) => lower === h || lower.startsWith(`${h}:`) || lower.startsWith(`${h}/`));
  if (!lower.startsWith("http://") && !lower.startsWith("https://") && !isLocal) return null;
  return isSafeLink(isLocal ? `http://${text}` : text);
}

const BARE_URL_RE = /https?:\/\/[^\s<>"'`]+/gi;

/** Extracts safe bare `http(s)://` URLs from plain text, trimming trailing sentence punctuation. */
export function bareLinks(text: string): { start: number; end: number; raw: string; url: string }[] {
  if (!text.includes("://")) return [];
  const results: { start: number; end: number; raw: string; url: string }[] = [];
  BARE_URL_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = BARE_URL_RE.exec(text)) !== null) {
    let end = m.index + m[0].length;
    while (end > m.index) {
      const last = text[end - 1];
      if (!".,;:!?)]}*_".includes(last)) break;
      const inside = text.slice(m.index, end - 1);
      if (last === ")" && inside.split("(").length > inside.split(")").length) break;
      end -= 1;
    }
    const raw = text.slice(m.index, end);
    const parsed = isSafeLink(raw);
    if (parsed) results.push({ start: m.index, end, raw, url: parsed.href });
  }
  return results;
}

function linkHtml(labelHtml: string, plainLabel: string, parsed: URL): string {
  const href = escapeHtml(parsed.href);
  const scheme = parsed.protocol.toLowerCase();
  const host = scheme === "http:" || scheme === "https:" ? parsed.hostname.toLowerCase() : "";
  const hostSuffix = host && !plainLabel.toLowerCase().includes(host) ? `<span class="link-host"> (${escapeHtml(host)})</span>` : "";
  return `<a href="${href}" data-external title="${href}">${labelHtml}</a>${hostSuffix}`;
}

export interface InlineOptions {
  /** Optional citation group renderer (`[1]`, `[1, 2]`). Defaults to `<sup class="cite" data-cite="1">1</sup>`. */
  citation?: (numbers: number[]) => string;
}

/** Renders inline Markdown (`code`, `**bold**`, `*italic*`, links with hover title + host suffix, bare URLs, citations). */
export function renderInlineMarkdown(text: string, options: InlineOptions = {}): string {
  // Tokenize raw code spans before HTML escaping so `<` and `*` inside code stay literal, and localhost links work.
  const placeholders: string[] = [];
  const hold = (html: string) => {
    placeholders.push(html);
    return `\u0000${placeholders.length - 1}\u0000`;
  };

  let work = text.replace(/`([^`\n]+)`/g, (_m, code: string) => {
    const escaped = escapeHtml(code);
    const url = codeLink(code);
    if (url) {
      const href = escapeHtml(url.href);
      return hold(`<a href="${href}" data-external title="${href}"><code>${escaped}</code></a>`);
    }
    return hold(`<code>${escaped}</code>`);
  });

  // Auto-link `<https://…>` angle-bracket links before escaping HTML.
  work = work.replace(/<(https?:\/\/[^\s<>]+)>/gi, (_m, rawUrl: string) => {
    const parsed = isSafeLink(rawUrl);
    if (!parsed) return `&lt;${escapeHtml(rawUrl)}&gt;`;
    return hold(linkHtml(escapeHtml(rawUrl), rawUrl, parsed));
  });

  // Escape remaining text.
  work = escapeHtml(work);

  // Markdown links `[label](url)` (allows balanced one-level parentheses in URL like Wikipedia links).
  work = work.replace(/\[([^\]]+)\]\(([^)\s]+(?:\([^)\s]*\)[^)\s]*)*)(?:\s+&quot;[^&]*&quot;)?\)/g, (whole, label: string, rawUrl: string) => {
    const unescapedUrl = rawUrl.replace(/&amp;/g, "&");
    const parsed = isSafeLink(unescapedUrl);
    if (!parsed) return whole;
    const formattedLabel = formatInlineStyles(label);
    return hold(linkHtml(formattedLabel, label, parsed));
  });

  // Bare URLs in remaining plain text (never inside held placeholders).
  work = work
    .split(/(\u0000\d+\u0000)/g)
    .map((part) => {
      if (part.startsWith("\u0000")) return part;
      const unescapedPart = part.replace(/&amp;/g, "&");
      const found = bareLinks(unescapedPart);
      if (!found.length) return formatInlineStyles(part);
      let cursor = 0;
      const segs: string[] = [];
      for (const hit of found) {
        if (hit.start > cursor) segs.push(formatInlineStyles(escapeHtml(unescapedPart.slice(cursor, hit.start))));
        const parsed = isSafeLink(hit.url)!;
        segs.push(hold(linkHtml(escapeHtml(hit.raw), hit.raw, parsed)));
        cursor = hit.end;
      }
      if (cursor < unescapedPart.length) segs.push(formatInlineStyles(escapeHtml(unescapedPart.slice(cursor))));
      return segs.join("");
    })
    .join("");

  if (options.citation) {
    work = work.replace(/((?:\[\d{1,3}(?:\s*,\s*\d{1,3})*\])+)(?!\()/g, (whole) => {
      const numbers = [...whole.matchAll(/\d{1,3}/g)].map((m) => Number(m[0]));
      return options.citation!(numbers);
    });
  } else {
    work = work.replace(/\[(\d{1,2})\]/g, '<sup class="cite" data-cite="$1">$1</sup>');
  }

  return work.replace(/\u0000(\d+)\u0000/g, (_m, i: string) => placeholders[Number(i)]);
}

function formatInlineStyles(escaped: string): string {
  return escaped
    .replace(/~~([^~]+)~~/g, "<del>$1</del>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/(^|[^*])\*([^*\s][^*]*)\*/g, "$1<em>$2</em>");
}

// --- Tables (`TableText` & numeric column alignment) ---

export function stripCellMarkdown(text: string): string {
  return text.replace(/\*\*/g, "").replace(/`/g, "");
}

export function tableToMarkdown(header: string[], rows: string[][]): string {
  const line = (cells: string[]) => `| ${cells.map((c) => c.replace(/\|/g, "\\|")).join(" | ")} |`;
  return [line(header), line(header.map(() => "---")), ...rows.map(line)].join("\n");
}

export function tableToCsv(header: string[], rows: string[][]): string {
  const cell = (raw: string) => {
    const plain = stripCellMarkdown(raw);
    if (!/[,"\n]/.test(plain)) return plain;
    return `"${plain.replace(/"/g, '""')}"`;
  };
  return [header, ...rows].map((row) => row.map(cell).join(",")).join("\n");
}

export function isNumericColumn(rows: string[][], column: number): boolean {
  if (!rows.length) return false;
  return rows.every((row) => {
    const raw = stripCellMarkdown(row[column] ?? "").trim();
    if (!raw || raw === "-" || raw === "–") return true;
    // Accept formatted numbers / percentages / currency (`€ 12,50`, `1,234.56`, `+3%`, `-4.2`).
    return /^[$€£¥+-]?\s*\d[\d.,\s]*%?$/.test(raw);
  });
}

// --- HTML / SVG sandboxed preview (`CodeRender`) ---

export function canPreviewCode(language: string): boolean {
  const lang = language.trim().toLowerCase();
  return lang === "html" || lang === "svg";
}

const PREVIEW_CSP = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: https: http://localhost:*; font-src data:;">`;

/** Builds an isolated HTML document for `<iframe sandbox="" srcdoc={…}>` (no scripts, forms, or navigation). */
export function previewSrcdoc(language: string, code: string): string {
  if (language.trim().toLowerCase() === "svg") {
    return `<!doctype html><html><head>${PREVIEW_CSP}<style>html,body{margin:0;padding:12px;background:#fff;display:flex;align-items:center;justify-content:center;min-height:100vh;box-sizing:border-box}svg{max-width:100%;height:auto}</style></head><body>${code}</body></html>`;
  }
  if (/<head[\s>]/i.test(code)) {
    return code.replace(/<head([^>]*)>/i, `<head$1>${PREVIEW_CSP}`);
  }
  if (/<html[\s>]/i.test(code)) {
    return code.replace(/<html([^>]*)>/i, `<html$1><head>${PREVIEW_CSP}</head>`);
  }
  return `<!doctype html><html><head>${PREVIEW_CSP}</head><body>${code}</body></html>`;
}
