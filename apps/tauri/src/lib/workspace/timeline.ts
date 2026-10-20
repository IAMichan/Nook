// Hoe de tijdlijn van een sessie leest (TimelinePresentation, TimelineSearch, TimelineContainers, FailureJump,
// PlanPreview en ContextMeter op de Mac): een afgeronde beurt vouwt tot "2m 13s gewerkt" tussen jouw bericht en het
// antwoord, tool-aanroepen achter elkaar worden één regel ("3 commando's uitgevoerd en 2 bestanden gewijzigd"), en
// terwijl de agent werkt zegt één levende regel wat hij doet en denkt. Geen interface-code, zodat tests het los gebruiken.
import type { RunEvent } from "./api";

export type ToolCategory = "command" | "edit" | "read" | "search" | "other";
const ORDER: ToolCategory[] = ["command", "edit", "read", "search", "other"];

const TOOL_PREFIX = "mcp__nook__";

/// Claude Code, Codex, Gemini CLI en Nooks eigen tools op naam.
export function categoryOf(tool: string): ToolCategory {
  const name = tool.toLowerCase();
  if (name.startsWith(TOOL_PREFIX)) return name.slice(TOOL_PREFIX.length) === "terminal_run" ? "command" : "other";
  switch (name) {
    case "bash": case "shell": case "run_shell_command": case "nook terminal": case "killshell": case "bashoutput":
      return "command";
    case "edit": case "multiedit": case "write": case "notebookedit": case "write_file": case "replace": case "apply_patch":
      return "edit";
    case "read": case "read_file": case "read_many_files": case "ls": case "list_directory": case "notebookread":
      return "read";
    case "grep": case "glob": case "search_file_content": case "websearch": case "webfetch": case "web_search": case "web_fetch":
    case "google_web_search":
      return "search";
    default:
      return "other";
  }
}

/// An identifier as words (McpToolName.readable on the Mac): "move_file" and "moveFile" read as "Move file"; acronyms
/// and words written with a capital after a separator keep their case ("get_URL" is "Get URL").
export function readableName(name: string): string {
  const trimmed = name.trim();
  if (trimmed.includes(" ")) return trimmed;
  const words: { text: string; hump: boolean }[] = [];
  let current = "";
  let hump = false;
  for (const c of trimmed) {
    if ("_-./:".includes(c)) {
      if (current) words.push({ text: current, hump });
      current = "";
      hump = false;
    } else if (c !== c.toLowerCase() && current && /[\p{Ll}\p{N}]/u.test(current[current.length - 1])) {
      words.push({ text: current, hump });
      current = c;
      hump = true;
    } else {
      current += c;
    }
  }
  if (current) words.push({ text: current, hump });
  if (!words.length) return trimmed;
  return words
    .map(({ text, hump }, i) => {
      if (text.length > 1 && text === text.toUpperCase() && /\p{L}/u.test(text)) return text;
      if (i === 0) return text.charAt(0).toUpperCase() + text.slice(1).toLowerCase();
      if (!hump && text.charAt(0) !== text.charAt(0).toLowerCase()) return text;
      return text.toLowerCase();
    })
    .join(" ");
}

/// A tool by the name people read: an MCP tool (`mcp__server__move_file`) is "Move file"; any other stays as it is.
export function toolLabel(tool: string): string {
  if (!tool.startsWith("mcp__")) return tool;
  const parts = tool.slice(5).split("__");
  const name = parts[parts.length - 1];
  return parts.length >= 2 && name && parts.slice(0, -1).join("__") ? readableName(name) : tool;
}

/// Het bestandspad in de JSON-invoer van een tool, als die er een heeft.
export function pathOf(json: string | undefined): string | null {
  if (!json) return null;
  try {
    const o = JSON.parse(json);
    if (!o || typeof o !== "object") return null;
    for (const k of ["file_path", "notebook_path", "absolute_path", "path"]) {
      if (typeof o[k] === "string" && o[k]) return o[k];
    }
  } catch {
    // Geen JSON: geen pad.
  }
  return null;
}

export interface ToolTally {
  counts: Partial<Record<ToolCategory, number>>;
  failed: boolean;
}

/// Wat een groep tool-aanroepen deed, per soort geteld. Bewerkingen tellen bestanden, geen aanroepen.
export function tally(events: RunEvent[]): ToolTally {
  const counts: Partial<Record<ToolCategory, number>> = {};
  const edited = new Set<string>();
  let edits = 0;
  let failed = false;
  for (const e of events) {
    if (e.state === "failed") failed = true;
    if (e.kind === "fileChange") {
      edited.add(e.detail ?? e.text);
    } else if (e.kind === "tool") {
      const c = categoryOf(e.tool ?? "");
      if (c === "edit") {
        const p = pathOf(e.detail);
        if (p) edited.add(p);
        else edits += 1;
      } else {
        counts[c] = (counts[c] ?? 0) + 1;
      }
    }
  }
  const editCount = Math.max(edited.size, edits);
  if (editCount > 0) counts.edit = editCount;
  return { counts, failed };
}

/// De soorten met een aantal, in de volgorde van de samenvatting.
export function parts(t: ToolTally): { category: ToolCategory; count: number }[] {
  return ORDER.filter((c) => (t.counts[c] ?? 0) > 0).map((c) => ({ category: c, count: t.counts[c]! }));
}

const PHRASES: Record<ToolCategory, [string, string]> = {
  command: ["1 commando uitgevoerd", "%d commando's uitgevoerd"],
  edit: ["1 bestand gewijzigd", "%d bestanden gewijzigd"],
  read: ["1 bestand gelezen", "%d bestanden gelezen"],
  search: ["1 keer gezocht", "%d keer gezocht"],
  other: ["1 andere actie", "%d andere acties"],
};

function phrase(c: ToolCategory, n: number): string {
  return n === 1 ? PHRASES[c][0] : PHRASES[c][1].replace("%d", String(n));
}

/// "3 commando's uitgevoerd en 2 bestanden gewijzigd": de twee belangrijkste soorten, dan hoeveel acties nog meer.
export function sentence(t: ToolTally): string {
  const p = parts(t);
  if (p.length === 0) return "0 andere acties";
  const named = p.slice(0, 2).map((x) => phrase(x.category, x.count));
  const rest = p.slice(2).reduce((s, x) => s + x.count, 0);
  if (rest > 0) return `${named[0]}, ${named[1]} en nog ${rest} acties`;
  return named.length === 2 ? `${named[0]} en ${named[1]}` : named[0];
}

export type TimelineBlock =
  | { type: "event"; id: string; event: RunEvent }
  | { type: "tools"; id: string; events: RunEvent[]; tally: ToolTally }
  | { type: "fold"; id: string; seconds: number; blocks: TimelineBlock[] };

export interface LiveActivity {
  tool: string | null;
  thought: string | null;
}

/// Een beurt begint bij elk bericht van jou; wat ervoor staat is een beurt op zich.
export function split(events: RunEvent[]): RunEvent[][] {
  const turns: RunEvent[][] = [];
  for (const e of events) {
    if (e.kind === "user" || turns.length === 0) turns.push([e]);
    else turns[turns.length - 1].push(e);
  }
  return turns;
}

/// Groepeert de events van een sessie tot blokken. `active`: de laatste beurt loopt nog en vouwt nooit.
export function blocks(events: RunEvent[], active: boolean): TimelineBlock[] {
  const turns = split(events);
  return turns.flatMap((turn, i) => present(turn, i === turns.length - 1 && active));
}

function findLast<T>(list: T[], f: (x: T) => boolean): T | undefined {
  for (let i = list.length - 1; i >= 0; i--) if (f(list[i])) return list[i];
  return undefined;
}

function findLastIndex<T>(list: T[], f: (x: T) => boolean): number {
  for (let i = list.length - 1; i >= 0; i--) if (f(list[i])) return i;
  return -1;
}

const ev = (event: RunEvent): TimelineBlock => ({ type: "event", id: event.id, event });

function present(turn: RunEvent[], open: boolean): TimelineBlock[] {
  const first = turn[0];
  if (!first) return [];
  const finished = findLast(turn, (e) => e.kind === "result");
  const troubled =
    turn.some((e) => e.kind === "error" || (e.kind === "approval" && e.state === "pending")) || finished?.state === "failed";
  const answer = findLastIndex(turn, (e) => e.kind === "assistant");
  // Alleen een beurt die goed afliep vouwt: het antwoord blijft staan, het werk ertussen gaat dicht.
  if (open || first.kind !== "user" || !finished || troubled || answer < 0) return group(turn);
  const work = turn.filter((e, i) => i !== 0 && i !== answer && e.kind !== "result");
  if (!work.some((e) => e.kind !== "assistant")) return group(turn);
  const seconds = Math.max(0, (Date.parse(finished.date) - Date.parse(first.date)) / 1000);
  // De vouw krijgt het id van het eerste werk dat hij verbergt: nooit hetzelfde als een blok ernaast.
  return [ev(first), { type: "fold", id: work[0].id, seconds, blocks: group(work) }, ev(turn[answer]), ev(finished)];
}

/// Twee of meer tool-aanroepen achter elkaar worden één blok. De rest staat op zichzelf: het denken blijft leesbaar,
/// en fouten en toestemmingsvragen verdwijnen nooit in een groep.
export function group(events: RunEvent[]): TimelineBlock[] {
  const out: TimelineBlock[] = [];
  let run: RunEvent[] = [];
  const isWork = (e: RunEvent) => e.kind === "tool" || e.kind === "fileChange";
  const flush = () => {
    const trailing: RunEvent[] = [];
    while (run.length && !isWork(run[run.length - 1])) trailing.unshift(run.pop()!);
    if (run.filter(isWork).length >= 2) out.push({ type: "tools", id: run[0].id, events: run, tally: tally(run) });
    else out.push(...run.map(ev));
    out.push(...trailing.map(ev));
    run = [];
  };
  for (const e of events) {
    if (isWork(e)) {
      run.push(e);
    } else {
      flush();
      out.push(ev(e));
    }
  }
  flush();
  return out;
}

export function oneLine(text: string, limit: number): string {
  const single = text.replace(/\s+/g, " ").trim();
  return [...single].length > limit ? [...single].slice(0, limit).join("") + "…" : single;
}

/// De eerste vetgedrukte kop van een gedachte ("**De tests nakijken**"), of de eerste zin.
export function headline(text: string, limit = 110): string {
  const start = text.indexOf("**");
  if (start >= 0) {
    const end = text.indexOf("**", start + 2);
    if (end > start) {
      const bold = text.slice(start + 2, end).trim();
      if (bold) return oneLine(bold, limit);
    }
  }
  const flat = oneLine(text, 400);
  const stop = flat.search(/[.!?]/);
  if (stop >= 0) {
    const s = flat.slice(0, stop + 1);
    if (s.length >= 12) return oneLine(s, limit);
  }
  return oneLine(flat, limit);
}

/// De levende regel voor de lopende beurt: de tool die loopt (of het laatst liep) en waar de agent het laatst aan dacht.
export function live(events: RunEvent[]): LiveActivity {
  const turns = split(events);
  const turn = turns[turns.length - 1] ?? [];
  const tool = findLast(turn, (e) => e.kind === "tool" && e.state === "running") ?? findLast(turn, (e) => e.kind === "tool");
  const thinking = findLast(turn, (e) => e.kind === "thinking");
  const thought = thinking ? headline(thinking.text) : null;
  return { tool: tool?.text ?? null, thought: thought || null };
}

/// Welke dichte blokken (groep, vouw) welk event verbergen, buitenste eerst, zodat een zoekresultaat erin ze kan openen.
export function containers(list: TimelineBlock[]): Record<string, string[]> {
  const result: Record<string, string[]> = {};
  const walk = (blocks: TimelineBlock[], inside: string[]) => {
    for (const b of blocks) {
      if (b.type === "tools") {
        for (const e of b.events) result[e.id] = [...inside, "group:" + b.id];
      } else if (b.type === "fold") {
        const path = [...inside, "fold:" + b.id];
        for (const inner of b.blocks) {
          if (inner.type === "event") result[inner.event.id] = path;
          else if (inner.type === "tools") for (const e of inner.events) result[e.id] = [...path, "group:" + inner.id];
        }
      }
    }
  };
  walk(list, []);
  return result;
}

// MARK: Zoeken in de sessie

export type SearchField = "text" | "detail" | "output";
export interface SearchMatch { eventId: string; field: SearchField; start: number; end: number }
export interface SearchResult { state: "idle" | "results" | "noResults" | "failed"; matches: SearchMatch[] }

export const MAX_QUERY = 500;

/// Hoofdletters en accenten tellen niet mee; de zoektekst is letterlijke tekst, nooit een patroon.
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
}

export function search(events: RunEvent[], query: string, includeThinking = false): SearchResult {
  if (!query.trim()) return { state: "idle", matches: [] };
  if (query.length > MAX_QUERY) return { state: "failed", matches: [] };
  const needle = fold(query);
  const matches: SearchMatch[] = [];
  for (const e of events) {
    if (!includeThinking && e.kind === "thinking") continue;
    const fields: [SearchField, string | undefined][] = [["text", e.text], ["detail", e.detail], ["output", e.output]];
    for (const [field, value] of fields) {
      if (!value) continue;
      // Per teken vouwen zodat de posities in de oorspronkelijke tekst blijven kloppen.
      const map: number[] = [];
      let hay = "";
      for (let i = 0; i < value.length; i++) {
        const f = fold(value[i]);
        for (let j = 0; j < f.length; j++) map.push(i);
        hay += f;
      }
      map.push(value.length);
      let from = 0;
      for (;;) {
        const at = hay.indexOf(needle, from);
        if (at < 0 || needle.length === 0) break;
        matches.push({ eventId: e.id, field, start: map[at], end: map[at + needle.length - 1] + 1 });
        from = at + needle.length;
      }
    }
  }
  return { state: matches.length ? "results" : "noResults", matches };
}

export function countLabel(r: SearchResult, current: number | null): string {
  if (!r.matches.length) return "0/0";
  if (current === null || current < 0 || current >= r.matches.length) return `0/${r.matches.length}`;
  return `${current + 1}/${r.matches.length}`;
}

export function nextMatch(r: SearchResult, index: number | null, wrap = true): number | null {
  if (!r.matches.length) return null;
  if (index === null) return 0;
  if (index + 1 < r.matches.length) return index + 1;
  return wrap ? 0 : null;
}

export function previousMatch(r: SearchResult, index: number | null, wrap = true): number | null {
  if (!r.matches.length) return null;
  if (index === null) return r.matches.length - 1;
  if (index > 0) return index - 1;
  return wrap ? r.matches.length - 1 : null;
}

// MARK: Fouten, plannen, context

const isFailure = (e: RunEvent) => e.kind === "error" || (e.kind === "tool" && e.state === "failed");

/// Het doel van "Ga naar fout": de eerste mislukte tool-aanroep of fout.
export function firstFailure(events: RunEvent[]): string | null {
  return events.find(isFailure)?.id ?? null;
}

export function planTitle(markdown: string): string | null {
  for (const line of markdown.split(/\r?\n/)) {
    const t = line.trim();
    if (!t.startsWith("#")) continue;
    const text = t.replace(/^#+/, "").trim();
    if (text) return text;
  }
  return null;
}

export function planNeedsExpand(text: string): boolean {
  return text.length > 900 || text.split(/\r?\n/).length > 20;
}

/// De eerste `max` niet-lege regels; "..." zegt dat er meer volgt.
export function planPreview(text: string, max = 10): string {
  const all = text.split(/\r?\n/).map((l) => l.replace(/\s+$/, ""));
  const out: string[] = [];
  let visible = 0;
  let more = false;
  for (const line of all) {
    const isVisible = line.trim() !== "";
    if (isVisible && visible >= max) {
      more = true;
      break;
    }
    out.push(line);
    if (isVisible) visible += 1;
  }
  while (out.length && out[out.length - 1].trim() === "") out.pop();
  if (!out.length) return planTitle(text) ?? "";
  if (more) out.push("", "...");
  return out.join("\n");
}

export function planFileName(title: string): string {
  const cleaned = title
    .toLowerCase()
    .replace(/[`'".,!?()[\]{}]+/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return (cleaned || "plan") + ".md";
}

export function contextLevel(fraction: number): "normal" | "warning" | "critical" {
  return fraction > 0.9 ? "critical" : fraction >= 0.75 ? "warning" : "normal";
}

export function contextPercent(fraction: number): string {
  const pct = Math.min(Math.max(fraction, 0), 1) * 100;
  return pct < 10 ? `${pct.toFixed(1)}%` : `${Math.round(pct)}%`;
}

/// "< 1 min", "12 min", "2u 5m", "3 d" (AgentPathFormat.duration).
export function duration(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  if (minutes < 1) return "< 1 min";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return minutes % 60 === 0 ? `${hours}u` : `${hours}u ${minutes % 60}m`;
  return `${Math.floor(hours / 24)} d`;
}
