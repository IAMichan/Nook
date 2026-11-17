// Pure citation logic for Nook's answers (`Citations`, `SourcePassage`, `AnswerCitation` on macOS):
// - strips model-written "Sources:" lists from live and previously saved answers
// - labels inline citations by sender (mail) or short title
// - picks and highlights the lines in a source excerpt that match the sentence before a citation
import type { SourceReference } from "./types";
import { sourceTitle } from "./sources";

export interface PassageLine {
  text: string;
  /** Shares words with the sentence: what the answer took from the source. */
  relevant: boolean;
}

const CITATION_RE = /\[(\d{1,3}(?:\s*,\s*\d{1,3})*)\](?!\()/g;

/** All citation numbers referenced in `text` (from `[1]` or `[2, 3]`, ignoring markdown links). */
export function citationsUsed(text: string): Set<number> {
  const result = new Set<number>();
  for (const m of text.matchAll(CITATION_RE)) {
    for (const part of m[1].split(",")) {
      const n = Number(part.trim());
      if (Number.isInteger(n) && n > 0) result.add(n);
    }
  }
  return result;
}

const SOURCE_LABELS = "sources?|bronnen|bron|quellen?|fuentes?";
const SOURCE_LIST_LINE_RE = new RegExp(
  `^\\s*(?:[-*]\\s+)?(?:[*_]{1,2})?(?:${SOURCE_LABELS})(?:[*_]{1,2})?\\s*:(?:[*_]{1,2})?(.*)$`,
  "i",
);
const SOURCE_LIST_HEADING_RE = new RegExp(
  `^\\s*(?:#{1,6}\\s*|[*_]{1,2})(?:${SOURCE_LABELS})\\s*:?\\s*(?:[*_]{1,2})?\\s*$`,
  "i",
);

/**
 * The answer without a list of its sources written out by the model ("Sources: [4] Vimexx · [8] WhatsApp …",
 * or a "Sources" heading over cited lines): Nook shows every source beside the fact it backs, so such a list
 * only repeats them. Ordinary prose mentioning sources without citations stays untouched.
 */
export function withoutSourceList(text: string): string {
  if (!text.includes("[") || citationsUsed(text).size === 0) return text;
  const lines = text.split("\n");
  let index = 0;
  let changed = false;
  while (index < lines.length) {
    const line = lines[index];
    let remainder: string | null = null;
    if (line.length < 600) {
      const m = line.match(SOURCE_LIST_LINE_RE);
      if (m) remainder = m[1];
    }
    if (remainder === null && line.length < 60 && SOURCE_LIST_HEADING_RE.test(line)) {
      remainder = "";
    }
    if (remainder === null) {
      index += 1;
      continue;
    }
    const rest = remainder.trim();
    let end = index + 1;
    if (!rest) {
      if (end + 1 < lines.length && !lines[end].trim() && citationsUsed(lines[end + 1]).size > 0) end += 1;
      while (end < lines.length && lines[end].trim() && citationsUsed(lines[end]).size > 0) end += 1;
      if (!(end > index + 1 && citationsUsed(lines[end - 1]).size > 0)) {
        index += 1;
        continue;
      }
    } else if (citationsUsed(rest).size === 0) {
      index += 1;
      continue;
    }
    lines.splice(index, end - index);
    changed = true;
  }
  if (!changed) return text;
  return lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

export function isOpenableUrl(raw?: string | null): boolean {
  if (!raw) return false;
  try {
    const parsed = new URL(raw);
    if (parsed.protocol === "https:") return Boolean(parsed.hostname);
    return parsed.protocol === "file:" || parsed.protocol === "message:";
  } catch {
    return false;
  }
}

/** Who sent a mail ("Vimexx" from its detail "Vimexx · 2026-11-14"); null for any other source. */
export function referenceSender(ref: SourceReference): string | null {
  const mail = ref.sourceId.toLowerCase().includes("mail") || Boolean(ref.url?.startsWith("message:"));
  if (!mail) return null;
  const name = ref.detail.split(" · ")[0]?.trim() ?? "";
  if (!name || /^\d/.test(name)) return null;
  return name;
}

/** The source's name without the app prefix ("Mama Jis" for "WhatsApp: Mama Jis"). */
export function referenceShortTitle(ref: SourceReference): string {
  const idx = ref.title.indexOf(": ");
  if (idx >= 0 && idx <= 20) return ref.title.slice(idx + 2);
  return ref.title;
}

/** Where the source is from ("WhatsApp", "Mail"), with its detail: the line above its title in a preview. */
export function referenceOrigin(ref: SourceReference): string {
  const idx = ref.title.indexOf(": ");
  const app = idx >= 0 && idx <= 20 ? ref.title.slice(0, idx) : sourceTitle(ref.sourceId);
  return [app, ref.detail].filter((s) => s && s.trim().length > 0).join(" · ");
}

/** The sources a citation of `numbers` names, each once, in the order it names them. */
export function citationReferences(numbers: number[], references: SourceReference[]): SourceReference[] {
  const seen = new Set<number>();
  const result: SourceReference[] = [];
  for (const n of numbers) {
    if (seen.has(n)) continue;
    seen.add(n);
    const ref = references.find((r) => r.number === n);
    if (ref) result.push(ref);
  }
  return result;
}

export const CITATION_LABEL_LENGTH = 22;

/** A citation pill's label: first source's sender or short name, cut to 22 chars, and "+N" for more. */
export function citationLabel(references: SourceReference[]): string {
  const first = references[0];
  if (!first) return "";
  let name = (referenceSender(first) ?? referenceShortTitle(first)).trim();
  if (!name) name = sourceTitle(first.sourceId) || first.sourceId;
  if (name.length > CITATION_LABEL_LENGTH) {
    name = `${name.slice(0, CITATION_LABEL_LENGTH - 1).trimEnd()}…`;
  }
  return references.length > 1 ? `${name} +${references.length - 1}` : name;
}

function withoutTitle(line: string, title: string): string {
  if (!title || !line.toLowerCase().startsWith(title.toLowerCase())) return line;
  const rest = line.slice(title.length).trim();
  if (rest && !rest.startsWith("|") && !rest.startsWith("·")) return line;
  return rest.replace(/^[|·]+/, "").trim();
}

const ISO_TIME_RE = /(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?/g;

/** A line as a person reads it: "2026-11-16 13:00" for an ISO time, and "·" instead of "|". */
export function readablePassageLine(line: string): string {
  const withTime = line.includes("T") ? line.replace(ISO_TIME_RE, "$1 $2") : line;
  return withTime.replaceAll(" | ", " · ");
}

const STOP_WORDS = new Set([
  "that", "this", "with", "from", "have", "they", "will", "your", "there", "about", "what", "when", "which",
  "deze", "voor", "niet", "maar", "heeft", "hebben", "naar", "wordt", "worden", "jouw", "staat", "staan", "waar", "over",
  "dass", "nicht", "eine", "einen", "sind", "wird", "dann", "auch", "noch", "oder", "aber",
  "dans", "pour", "avec", "sont", "mais", "plus", "vous", "votre",
  "para", "pero", "esta", "este", "como", "sobre", "tiene",
]);

/** The words of a sentence worth matching: four letters or more, or a number of two digits or more, lowercased. */
export function passageTerms(text: string): string[] {
  const words = text.toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  const seen = new Set<string>();
  const result: string[] = [];
  for (const word of words) {
    const isNumber = /^\d+$/.test(word);
    if (isNumber ? word.length < 2 : word.length < 4) continue;
    if (STOP_WORDS.has(word) || seen.has(word)) continue;
    seen.add(word);
    result.push(word);
  }
  return result;
}

/** A line cut to `width` characters around `word` (its start when there is none), with "…" where it was cut. */
export function clipPassageLine(line: string, around: string | null, width: number): string {
  if (line.length <= width) return line;
  let start = 0;
  if (around) {
    const offset = line.toLowerCase().indexOf(around.toLowerCase());
    if (offset >= 0) start = Math.max(0, Math.min(offset - Math.floor(width / 3), line.length - width));
  }
  const end = Math.min(line.length, start + width);
  return (start > 0 ? "…" : "") + line.slice(start, end).trim() + (end < line.length ? "…" : "");
}

/**
 * At most `limit` lines of `excerpt` around the best match for `claim`; each line at most `width` characters,
 * cut around its first matching word. With nothing in common, the source's first lines, none marked.
 */
export function pickPassage(
  excerpt: string | null | undefined,
  claim: string,
  title = "",
  limit = 7,
  width = 240,
): PassageLine[] {
  if (!excerpt) return [];
  const lines = excerpt
    .split("\n")
    .map((l) => readablePassageLine(withoutTitle(l.trim(), title)))
    .filter(Boolean);
  if (!lines.length) return [];
  const words = passageTerms(claim);
  const scores = lines.map((line) => {
    const lower = line.toLowerCase();
    return words.reduce((acc, w) => acc + (lower.includes(w) ? 1 : 0), 0);
  });
  const best = Math.max(...scores);
  if (best <= 0) {
    return lines.slice(0, limit).map((l) => ({ text: clipPassageLine(l, null, width), relevant: false }));
  }
  const top = scores.indexOf(best);
  const start = Math.max(0, Math.min(top - 1, lines.length - limit));
  const threshold = Math.max(1, Math.floor((best + 1) / 2));
  const result: PassageLine[] = [];
  if (start > 0) result.push({ text: clipPassageLine(lines[0], null, width), relevant: scores[0] >= threshold });
  const end = Math.min(lines.length, start + limit - result.length);
  for (let i = start; i < end; i++) {
    const lower = lines[i].toLowerCase();
    const hit = words.find((w) => lower.includes(w)) ?? null;
    result.push({ text: clipPassageLine(lines[i], hit, width), relevant: scores[i] >= threshold });
  }
  return result;
}

/**
 * Given the text from the start of a block (or after the previous citation) up to a citation pill, returns the
 * sentence slice that the citation backs (after the last `. `, `! `, `? `, `; ` or newline, trimmed).
 */
export function claimFromTextBefore(textBefore: string): string {
  let start = 0;
  for (let i = textBefore.length - 1; i >= 0; i--) {
    const ch = textBefore[i];
    if (ch === "\n" || ch === "\t") {
      start = i + 1;
      break;
    }
    if ((ch === "." || ch === "!" || ch === "?" || ch === ";") && i + 1 < textBefore.length && /\s/.test(textBefore[i + 1])) {
      start = i + 1;
      break;
    }
  }
  return textBefore
    .slice(start)
    .replace(/^[\s.,!?;:()\[\]"'“”‘’«»—–-]+/, "")
    .trim();
}
