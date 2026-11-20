// Search everything (Ctrl+K), as the Mac's `SearchPanel` with `SearchIndex`, `SearchQuery` and `SearchAI` do it. The
// interface reads the query language ("exact words", -word, a OR b, in:kind, is:flag, from:, key:value facets,
// after:/before:/on: dates, /regex/) and searches what it holds itself (actions, Settings pages, the session lists);
// the backend (`search_everything`, `nook_core::search`) searches the text only it holds (every message of every
// conversation, agent transcripts, chats of every app, call notes, memories) and hands back the passage that matched.
// Notices are left out: Windows keeps no notice history yet (docs/WINDOWS-PARITY.md).

export type SearchKind = "conversation" | "session" | "chat" | "note" | "memory" | "setting" | "action";

/** The kinds in chip order, as the Mac's (`SearchPanel.kinds`), without notices. */
export const searchKinds: SearchKind[] = ["conversation", "session", "chat", "note", "memory", "setting", "action"];

/** The kinds only the backend finds by their text. */
export const backendKinds: SearchKind[] = ["conversation", "session", "chat", "note", "memory"];

export interface SearchDoc {
  id: string;
  kind: SearchKind;
  title: string;
  /** Where it lives: the agent, project and branch of a session, a conversation's last line. */
  subtitle?: string;
  /** More words that find it without being shown (a setting's group, a session's last prompt). */
  text?: string;
  /** Milliseconds since 1970. */
  date?: number;
  /** For is: ("pinned", "archived", "running", "settled", "unread"…). */
  flags?: string[];
  /** For key:value ("agent", "project", "branch"). */
  facets?: Record<string, string>;
  /** Ranked a little higher (pinned, running) or lower. */
  boost?: number;
  /** The backend found the words in its passages: no need to find them in the title here. */
  contentHit?: boolean;
  /** What matched in its text, who wrote it, when, and where it is (the backend's best passage). */
  snippet?: string;
  author?: string;
  passageDate?: number;
  anchor?: string | null;
  /** How many of its passages matched. */
  matches?: number;
}

/** A hit as the backend sends it (`nook_core::search::Hit`). */
export interface BackendHit {
  id: string;
  kind: string;
  title: string;
  subtitle: string;
  date: string | null;
  flags: string[];
  facets: Record<string, string>;
  boost: number;
  snippet: string;
  author: string;
  passageDate: string | null;
  anchor: string | null;
  matches: number;
  score: number;
}

/** What the backend is asked (`nook_core::search::Request`). */
export interface BackendRequest {
  alternatives: string[][];
  excluded: string[];
  regex: string | null;
  from: string[];
  kinds: string[];
  limit: number;
}

export interface SearchHit {
  doc: SearchDoc;
  score: number;
  /** Where the typed words are in the title, as [start, end) offsets. */
  titleRanges: [number, number][];
}

export interface ParsedQuery {
  /** Either of these lists of words and phrases, each meaning all of its terms (a OR b). */
  alternatives: string[][];
  excluded: string[];
  kinds: string[];
  /** from: — only what these wrote ("me", "nook", a name); only the backend knows who wrote a passage. */
  from: string[];
  is: string[];
  isNot: string[];
  facets: [string, string][];
  after?: number;
  before?: number;
  regex?: RegExp;
}

/// Folds case and accents, so "geluid" finds "Geluid" and "reglages" finds "Réglages".
export function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

/** The folded text and, for each of its characters, the offset in the original it came from. */
function foldMap(text: string): { folded: string; at: number[] } {
  let folded = "";
  const at: number[] = [];
  let offset = 0;
  for (const ch of text) {
    const f = fold(ch);
    for (let i = 0; i < f.length; i++) at.push(offset);
    folded += f;
    offset += ch.length;
  }
  at.push(offset);
  return { folded, at };
}

const kindNames: Record<string, string> = {
  nook: "conversation", conversation: "conversation", conversations: "conversation", gesprek: "conversation", gesprekken: "conversation",
  agent: "session", agents: "session", session: "session", sessions: "session", sessies: "session",
  setting: "setting", settings: "setting", instellingen: "setting",
  action: "action", actions: "action", acties: "action",
  chat: "chat", chats: "chat", note: "note", notes: "note", notities: "note", call: "note", calls: "note",
  memory: "memory", memories: "memory", geheugen: "memory",
};

const DAY = 86400000;

/** A date as the Mac's query takes it: 2026-10-01, 7d, 2w, 3m, today, yesterday. Midnight that day, local time. */
export function parseDate(value: string, now = Date.now()): number | undefined {
  const v = value.toLowerCase();
  const midnight = (ms: number) => { const d = new Date(ms); d.setHours(0, 0, 0, 0); return d.getTime(); };
  if (v === "today" || v === "vandaag") return midnight(now);
  if (v === "yesterday" || v === "gisteren") return midnight(now - DAY);
  const rel = /^(\d+)([dwmy])$/.exec(v);
  if (rel) {
    const n = Number(rel[1]);
    const days = rel[2] === "d" ? n : rel[2] === "w" ? n * 7 : rel[2] === "m" ? n * 30 : n * 365;
    return midnight(now - days * DAY);
  }
  const abs = /^(\d{4})-(\d{1,2})(?:-(\d{1,2}))?$/.exec(v);
  if (abs) return new Date(Number(abs[1]), Number(abs[2]) - 1, Number(abs[3] ?? 1)).getTime();
  return undefined;
}

/** Reads what is typed into words, phrases and filters. */
export function parseQuery(text: string, now = Date.now()): ParsedQuery {
  const q: ParsedQuery = { alternatives: [[]], excluded: [], kinds: [], from: [], is: [], isNot: [], facets: [] };
  const tokens = text.match(/-?"[^"]*"?|\/(?:[^/\\]|\\.)+\/[a-z]*|\S+/g) ?? [];
  for (const raw of tokens) {
    if (raw === "OR") {
      if (q.alternatives[q.alternatives.length - 1].length) q.alternatives.push([]);
      continue;
    }
    const negative = raw.startsWith("-") && raw.length > 1;
    const token = negative ? raw.slice(1) : raw;
    if (token.startsWith('"')) {
      const phrase = fold(token.replace(/^"|"$/g, "").trim());
      if (!phrase) continue;
      (negative ? q.excluded : q.alternatives[q.alternatives.length - 1]).push(phrase);
      continue;
    }
    const regex = /^\/(.+)\/([a-z]*)$/.exec(token);
    if (regex && !negative) {
      try { q.regex = new RegExp(regex[1], regex[2].includes("i") ? regex[2] : regex[2] + "i"); } catch { /* typed halfway: no filter yet */ }
      continue;
    }
    const filter = /^([a-z]+):(.*)$/i.exec(token);
    if (filter) {
      const key = filter[1].toLowerCase();
      const value = filter[2];
      if (!value) continue;
      if (key === "in") { q.kinds.push(kindNames[value.toLowerCase()] ?? value.toLowerCase()); continue; }
      if (key === "from" && !negative) { q.from.push(fold(value)); continue; }
      if (key === "is") { (negative ? q.isNot : q.is).push(value.toLowerCase()); continue; }
      if (key === "after" || key === "before" || key === "on") {
        const date = parseDate(value, now);
        if (date === undefined) continue;
        if (key === "after") q.after = date;
        else if (key === "before") q.before = date;
        else { q.after = date; q.before = date + DAY; }
        continue;
      }
      q.facets.push([key, fold(value)]);
      continue;
    }
    const word = fold(token);
    if (word) (negative ? q.excluded : q.alternatives[q.alternatives.length - 1]).push(word);
  }
  q.alternatives = q.alternatives.filter((a) => a.length);
  return q;
}

/** Every word and phrase typed to find something (not to leave it out), once. */
export function positiveTerms(q: ParsedQuery): string[] {
  return [...new Set(q.alternatives.flat())];
}

/** True when the query asks for anything at all. */
export function hasQuery(q: ParsedQuery): boolean {
  return q.alternatives.length > 0 || q.excluded.length > 0 || q.kinds.length > 0 || q.from.length > 0 || q.is.length > 0 || q.isNot.length > 0
    || q.facets.length > 0 || q.after !== undefined || q.before !== undefined || q.regex !== undefined;
}

/** What the backend searches for: the words, left-out words, regex, authors and the kinds it holds. */
export function backendRequest(q: ParsedQuery, limit = 200): BackendRequest | null {
  const kinds = q.kinds.filter((k) => (backendKinds as string[]).includes(k));
  // in: asks only for what the backend does not hold (settings, actions): nothing to ask it.
  if (q.kinds.length && !kinds.length) return null;
  const words = q.alternatives.length > 0 || q.regex !== undefined || q.from.length > 0;
  if (!words && !kinds.length) return null;
  return { alternatives: q.alternatives, excluded: q.excluded, regex: q.regex?.source ?? null, from: q.from, kinds, limit };
}

/**
 * The interface's documents with what the backend found: a document it has too (a session, a conversation) gets the
 * passage; the rest (chats, notes, memories, earlier sessions) are added as they came.
 */
export function mergeBackend(docs: SearchDoc[], hits: BackendHit[]): SearchDoc[] {
  const byId = new Map(hits.map((h) => [h.id, h]));
  const extra = (h: BackendHit): Partial<SearchDoc> => ({
    contentHit: true, snippet: h.snippet || undefined, author: h.author || undefined, anchor: h.anchor,
    passageDate: h.passageDate ? Date.parse(h.passageDate) : undefined, matches: h.matches,
  });
  const out = docs.map((d) => (byId.has(d.id) ? { ...d, ...extra(byId.get(d.id)!) } : d));
  const known = new Set(docs.map((d) => d.id));
  for (const h of hits) {
    if (known.has(h.id) || !(searchKinds as string[]).includes(h.kind)) continue;
    out.push({
      id: h.id, kind: h.kind as SearchKind, title: h.title, subtitle: h.subtitle, date: h.date ? Date.parse(h.date) : undefined,
      flags: h.flags, facets: h.facets, boost: h.boost, ...extra(h),
    });
  }
  return out;
}

function haystack(doc: SearchDoc): string {
  return fold([doc.title, doc.subtitle ?? "", doc.text ?? "", ...Object.values(doc.facets ?? {})].join("\n"));
}

/** Whether a document passes the query, and how well it matches; null when it does not. */
export function scoreDoc(doc: SearchDoc, q: ParsedQuery, now = Date.now()): number | null {
  if (q.kinds.length && !q.kinds.includes(doc.kind)) return null;
  // Who wrote what only the backend knows: from: keeps what it found.
  if (q.from.length && !doc.contentHit) return null;
  const flags = doc.flags ?? [];
  if (q.is.some((f) => !flags.includes(f)) || q.isNot.some((f) => flags.includes(f))) return null;
  for (const [key, value] of q.facets) {
    const facet = doc.facets?.[key];
    if (facet === undefined || !fold(facet).includes(value)) return null;
  }
  if (q.after !== undefined && (doc.date === undefined || doc.date < q.after)) return null;
  if (q.before !== undefined && (doc.date === undefined || doc.date >= q.before)) return null;
  const hay = haystack(doc);
  if (q.excluded.some((t) => hay.includes(t))) return null;
  if (q.regex && !doc.contentHit && !q.regex.test([doc.title, doc.subtitle ?? "", doc.text ?? ""].join("\n"))) return null;
  const title = fold(doc.title);
  let best = q.alternatives.length ? -1 : 0;
  if (doc.contentHit && !q.alternatives.length) best = Math.log1p(doc.matches ?? 1) * 0.5;
  for (const alternative of q.alternatives) {
    if (!doc.contentHit && !alternative.every((t) => hay.includes(t))) continue;
    let score = doc.contentHit ? Math.log1p(doc.matches ?? 1) * 0.5 : 0;
    for (const term of alternative) {
      const at = title.indexOf(term);
      if (at < 0) { score += hay.includes(term) ? 1 : 0.5; continue; }
      score += 3;
      if (at === 0) score += 2;
      else if (/[\s\p{P}]/u.test(title[at - 1])) score += 1;
      if (title === term) score += 2;
    }
    best = Math.max(best, score);
  }
  if (best < 0) return null;
  // Recent things a little higher, as the Mac's ranking does: up to half a point over the last month.
  const recency = doc.date ? Math.max(0, 1 - (now - doc.date) / (30 * DAY)) * 0.5 : 0;
  return best + (doc.boost ?? 0) + recency;
}

/** Where the query's words are in a text, as [start, end) offsets, merged where they touch. */
export function highlightRanges(text: string, q: ParsedQuery): [number, number][] {
  const { folded, at } = foldMap(text);
  const ranges: [number, number][] = [];
  for (const term of positiveTerms(q)) {
    let from = 0;
    while (term && (from = folded.indexOf(term, from)) >= 0) {
      ranges.push([at[from], at[from + term.length]]);
      from += term.length;
    }
  }
  if (q.regex) {
    const global = new RegExp(q.regex.source, q.regex.flags.includes("g") ? q.regex.flags : q.regex.flags + "g");
    for (const m of text.matchAll(global)) if (m[0]) ranges.push([m.index, m.index + m[0].length]);
  }
  ranges.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const r of ranges) {
    const last = merged[merged.length - 1];
    if (last && r[0] <= last[1]) last[1] = Math.max(last[1], r[1]);
    else merged.push([r[0], r[1]]);
  }
  return merged;
}

/** A text cut into what matched and what did not, for drawing the matches bold. */
export function segments(text: string, ranges: [number, number][]): { text: string; marked: boolean }[] {
  const out: { text: string; marked: boolean }[] = [];
  let at = 0;
  for (const [start, end] of ranges) {
    if (start > at) out.push({ text: text.slice(at, start), marked: false });
    if (end > start) out.push({ text: text.slice(start, end), marked: true });
    at = Math.max(at, end);
  }
  if (at < text.length) out.push({ text: text.slice(at), marked: false });
  return out;
}

/** The documents that match, best first; with nothing asked, none. */
export function search(docs: SearchDoc[], q: ParsedQuery, now = Date.now()): SearchHit[] {
  if (!hasQuery(q)) return [];
  const hits: SearchHit[] = [];
  for (const doc of docs) {
    const score = scoreDoc(doc, q, now);
    if (score === null) continue;
    hits.push({ doc, score, titleRanges: highlightRanges(doc.title, q) });
  }
  return hits.sort((a, b) => b.score - a.score || (b.doc.date ?? 0) - (a.doc.date ?? 0));
}

/**
 * The rows as the Mac lists them: with all kinds shown and more than one hit, the best one under "Top", then the rest
 * per kind in chip order, open sessions before settled ones.
 */
export function grouped(hits: SearchHit[], kind: SearchKind | null): { hit: SearchHit; top: boolean }[] {
  const shown = kind ? hits.filter((h) => h.doc.kind === kind) : hits;
  const rows: { hit: SearchHit; top: boolean }[] = [];
  let rest = shown;
  if (!kind && shown.length > 1) {
    rows.push({ hit: shown[0], top: true });
    rest = shown.slice(1);
  }
  for (const group of searchKinds) {
    let inGroup = rest.filter((h) => h.doc.kind === group);
    if (group === "session") inGroup = [...inGroup.filter((h) => !isSettled(h.doc)), ...inGroup.filter((h) => isSettled(h.doc))];
    rows.push(...inGroup.map((hit) => ({ hit, top: false })));
  }
  return rows;
}

export function isSettled(doc: SearchDoc): boolean {
  return doc.flags?.includes("settled") ?? false;
}

/** Tab: the next kind that has hits, then back to all; Shift+Tab the other way. */
export function cycleKind(hits: SearchHit[], kind: SearchKind | null, backward = false): SearchKind | null {
  const present = searchKinds.filter((k) => hits.some((h) => h.doc.kind === k));
  if (!present.length) return null;
  const order: (SearchKind | null)[] = [null, ...present];
  const at = Math.max(0, order.indexOf(kind));
  return order[(at + (backward ? order.length - 1 : 1)) % order.length];
}

// MARK: Search with AI (`SearchAI` on the Mac)

/** The most sources the brain reads in all. */
export const maxSources = 10;

const stopwords = new Set([
  "a", "an", "the", "and", "or", "of", "to", "in", "on", "at", "for", "with", "about", "from", "by", "is", "are",
  "was", "were", "be", "been", "do", "does", "did", "what", "which", "who", "whom", "when", "where", "why", "how",
  "i", "me", "my", "we", "our", "you", "your", "it", "its", "that", "this", "there", "can", "could", "would",
  "should", "have", "has", "had", "find", "show", "tell", "search", "look", "all", "any", "some", "again",
  "de", "het", "een", "en", "of", "van", "naar", "op", "aan", "voor", "met", "over", "uit", "bij", "is", "zijn",
  "was", "waren", "wat", "welke", "wie", "wanneer", "waar", "waarom", "hoe", "ik", "mij", "mijn", "we", "wij",
  "ons", "onze", "je", "jij", "jouw", "die", "dat", "dit", "er", "kan", "kun", "kunt", "heb", "hebben", "had",
  "zoek", "vind", "laat", "zien", "toon", "nog", "ook", "al", "alle", "iets", "toen", "daar", "hier", "om", "te",
  "der", "die", "das", "ein", "eine", "und", "oder", "von", "zu", "im", "mit", "uber", "fur", "ist", "sind",
  "war", "wer", "wann", "wo", "warum", "wie", "ich", "mein", "meine", "wir", "du", "dein", "es",
  "le", "la", "les", "un", "une", "et", "ou", "du", "des", "au", "aux", "avec", "pour", "sur", "est", "sont",
  "que", "qui", "quoi", "quand", "pourquoi", "comment", "je", "mon", "ma", "mes", "nous", "vous", "il", "elle",
  "el", "los", "las", "uno", "una", "y", "o", "del", "con", "para", "por", "sobre", "es", "son", "fue",
  "quien", "cuando", "donde", "como", "yo", "mi", "mis", "nosotros", "tu", "su",
]);

const words = (text: string) => fold(text).split(/[^\p{L}\p{N}]+/u).filter(Boolean);

/** The question as one broad search: its words that carry meaning, any of them (a OR b). Empty when only filler is left. */
export function keywordQuery(question: string): string {
  const seen = new Set<string>();
  return words(question).filter((w) => w.length >= 2 && !stopwords.has(w) && !seen.has(w) && !!seen.add(w)).slice(0, 8).join(" OR ");
}

const openers = new Set([
  "what", "which", "who", "when", "where", "why", "how", "did", "do", "does", "is", "are", "was", "can",
  "wat", "welke", "wie", "wanneer", "waar", "waarom", "hoe", "heb", "hebben", "had", "zijn", "kan",
  "wer", "wann", "wo", "warum", "hat", "habe", "ist",
  "que", "quoi", "qui", "quand", "ou", "pourquoi", "comment", "est",
  "quien", "cuando", "donde", "por", "como", "cual",
]);

/** Whether typed text reads as a question rather than words to find: then the AI row comes first. */
export function looksLikeQuestion(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.endsWith("?")) return true;
  const w = words(trimmed);
  return w.length >= 3 && openers.has(w[0]);
}

/** The hits of several searches as one list: taken in turns (each search's best first), each once, at most `limit`. */
export function gather(lists: SearchHit[][], limit = maxSources): SearchHit[] {
  const out: SearchHit[] = [];
  const seen = new Set<string>();
  const longest = Math.max(0, ...lists.map((l) => l.length));
  for (let rank = 0; rank < longest; rank++) {
    for (const list of lists) {
      const hit = list[rank];
      // Actions and settings are not something to read an answer from.
      if (!hit || hit.doc.kind === "action" || hit.doc.kind === "setting" || seen.has(hit.doc.id)) continue;
      seen.add(hit.doc.id);
      out.push(hit);
      if (out.length === limit) return out;
    }
  }
  return out;
}

/** The sources an answer cites, by number (1 is the first), in the order it first names them; others left out. */
export function citations(answer: string, count: number): number[] {
  const found: number[] = [];
  for (const m of answer.matchAll(/\[(\d+(?:\s*,\s*\d+)*)\]/g)) {
    for (const part of m[1].split(",")) {
      const n = Number(part.trim());
      if (n >= 1 && n <= count && !found.includes(n)) found.push(n);
    }
  }
  return found;
}

/** The sources in the order to list them: the cited ones as the answer names them, then the rest. */
export function orderedByCitation<T>(sources: T[], cited: number[]): T[] {
  const first = cited.map((n) => sources[n - 1]).filter((s): s is T => s !== undefined);
  return [...first, ...sources.filter((s) => !first.includes(s))];
}

/** The answer as shown: thinking tags and a wrapping code fence stripped, trimmed (`SearchAI.clean` on the Mac). */
export function cleanAnswer(answer: string): string {
  let text = answer.replace(/<think>[\s\S]*?(?:<\/think>|$)/g, "").trim();
  if (text.startsWith("```") && text.endsWith("```") && text.length > 6) {
    text = text.slice(3, -3);
    const nl = text.indexOf("\n");
    if (nl >= 0) text = text.slice(nl + 1);
  }
  return text.trim();
}

export type AnswerToken =
  | { kind: "text"; text: string }
  | { kind: "bold"; text: string }
  | { kind: "italic"; text: string }
  | { kind: "code"; text: string }
  | { kind: "link"; text: string; href: string }
  | { kind: "cite"; text: string };

/** An answer cut into plain text and citation marks, for drawing the marks in the accent. */
export function answerPieces(answer: string, count: number): { text: string; cite: boolean }[] {
  const out: { text: string; cite: boolean }[] = [];
  let at = 0;
  for (const m of answer.matchAll(/\[(\d+(?:\s*,\s*\d+)*)\]/g)) {
    const ok = m[1].split(",").every((p) => { const n = Number(p.trim()); return n >= 1 && n <= count; });
    if (!ok) continue;
    if (m.index > at) out.push({ text: answer.slice(at, m.index), cite: false });
    out.push({ text: m[0], cite: true });
    at = m.index + m[0].length;
  }
  if (at < answer.length) out.push({ text: answer.slice(at), cite: false });
  return out;
}

/**
 * The AI answer as inline Markdown (bold, italic, code, safe links) with its citations [1], [2] marked in the accent,
 * matching `SearchPanel.answerText` on the Mac.
 */
export function answerTokens(answer: string, count: number): AnswerToken[] {
  const out: AnswerToken[] = [];
  const push = (token: AnswerToken) => {
    if (!token.text) return;
    const last = out[out.length - 1];
    if (token.kind === "text" && last?.kind === "text") last.text += token.text;
    else out.push(token);
  };
  const pattern = /`([^`\n]+)`|\*\*([^*\n]+)\*\*|(?<!\*)\*([^*\n]+)\*(?!\*)|\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)|\[(\d+(?:\s*,\s*\d+)*)\]/g;
  let at = 0;
  for (const m of answer.matchAll(pattern)) {
    const idx = m.index ?? 0;
    if (idx > at) push({ kind: "text", text: answer.slice(at, idx) });
    if (m[1] !== undefined) push({ kind: "code", text: m[1] });
    else if (m[2] !== undefined) push({ kind: "bold", text: m[2] });
    else if (m[3] !== undefined) push({ kind: "italic", text: m[3] });
    else if (m[4] !== undefined && m[5] !== undefined) push({ kind: "link", text: m[4], href: m[5] });
    else if (m[6] !== undefined) {
      const ok = m[6].split(",").every((p) => { const n = Number(p.trim()); return n >= 1 && n <= count; });
      push({ kind: ok ? "cite" : "text", text: m[0] });
    }
    at = idx + m[0].length;
  }
  if (at < answer.length) push({ kind: "text", text: answer.slice(at) });
  return out;
}

// MARK: What you searched and opened (`SearchCenter.recent`, `recentlyOpened`)

const RECENT = "nook.search.recent";
const OPENED = "nook.search.opened";
export const recentLimit = 8;
const openedLimit = 200;
export const recentlyOpenedShown = 5;

export type Opened = { count: number; last: number; doc: SearchDoc };

function read<T>(key: string, fallback: T): T {
  try { return JSON.parse(localStorage.getItem(key) ?? "null") ?? fallback; } catch { return fallback; }
}
function write(key: string, value: unknown) {
  try { localStorage.setItem(key, JSON.stringify(value)); } catch { /* the list lasts until the window closes */ }
}

export function loadRecent(): string[] {
  const list = read<unknown>(RECENT, []);
  return Array.isArray(list) ? list.filter((s): s is string => typeof s === "string") : [];
}

/** Keeps a search you opened something from, newest first, without repeats. */
export function rememberSearch(text: string, list = loadRecent()): string[] {
  const trimmed = text.trim();
  if (!trimmed) return list;
  const next = [trimmed, ...list.filter((s) => s.toLowerCase() !== trimmed.toLowerCase())].slice(0, recentLimit);
  write(RECENT, next);
  return next;
}

export function clearRecent(): string[] {
  try { localStorage.removeItem(RECENT); } catch { /* nothing kept */ }
  return [];
}

export function loadOpened(): Record<string, Opened> {
  const log = read<Record<string, Opened>>(OPENED, {});
  return log && typeof log === "object" ? log : {};
}

/** A hit was opened: it ranks a little higher next time and leads what you opened before you type. Not actions. */
export function rememberOpened(doc: SearchDoc, now = Date.now(), log = loadOpened()): Record<string, Opened> {
  if (doc.kind === "action") return log;
  const entry = log[doc.id] ?? { count: 0, last: now, doc };
  // Kept without what matched this time: the row shows its title and place.
  const kept: SearchDoc = { id: doc.id, kind: doc.kind, title: doc.title, subtitle: doc.subtitle, date: doc.date, flags: doc.flags, facets: doc.facets };
  const next = { ...log, [doc.id]: { count: entry.count + 1, last: now, doc: kept } };
  const trimmed = Object.fromEntries(Object.entries(next).sort((a, b) => b[1].last - a[1].last).slice(0, openedLimit));
  write(OPENED, trimmed);
  return trimmed;
}

/** What you opened lately, newest first, for the start page. */
export function recentlyOpened(log: Record<string, Opened>): SearchDoc[] {
  return Object.values(log).sort((a, b) => b.last - a.last).slice(0, recentlyOpenedShown).map((o) => o.doc);
}

/** Added to a document's score: more for what you open often and lately, fading over a month. */
export function openedBonus(log: Record<string, Opened>, now = Date.now()): Record<string, number> {
  return Object.fromEntries(Object.entries(log).map(([id, e]) => {
    const days = Math.max(0, (now - e.last) / DAY);
    return [id, Math.min(1.5, 0.6 * Math.log2(1 + e.count)) * Math.exp(-days / 30)];
  }));
}
