// A session's conversation as the iPhone app lays it out (`TranscriptRow` in apps/ios/NookCompanion/TranscriptViews.swift,
// the Mac's `TranscriptPresentation`): your message, a finished turn folded into "Worked for …" with its final answer, and
// the turn that runs with how long it goes, the work so far and the step that runs now. Steps in a row read as one line
// ("Ran 3 commands and read 2 files") with a verb per step ("Ran npm test").
import type { TimelineEntry } from "./companion";
import { tr } from "./i18n.svelte";

export type TranscriptRow =
  | { kind: "user"; id: string; entry: TimelineEntry }
  | { kind: "answer"; id: string; entry: TimelineEntry; final: boolean }
  | { kind: "work"; id: string; steps: TimelineEntry[] }
  | { kind: "notice"; id: string; entry: TimelineEntry }
  | { kind: "fold"; id: string; seconds: number | null; rows: TranscriptRow[] }
  | { kind: "working"; id: "working"; since: number | null }
  | { kind: "live"; id: "live"; entry: TimelineEntry | null };

const isNotice = (e: TimelineEntry) => e.kind === "notice" || e.kind === "error";

/** A turn starts at each message of yours. */
export function transcriptRows(entries: TimelineEntry[], working: boolean): TranscriptRow[] {
  const turns: TimelineEntry[][] = [];
  for (const entry of entries) {
    if (entry.kind === "user" || !turns.length) turns.push([entry]);
    else turns[turns.length - 1].push(entry);
  }
  return turns.flatMap((turn, i) => (working && i === turns.length - 1 ? open(turn) : closed(turn)));
}

function closed(turn: TimelineEntry[]): TranscriptRow[] {
  const first = turn[0];
  if (!first) return [];
  let answer = -1;
  for (let i = turn.length - 1; i >= 0; i--) if (turn[i].kind === "assistant") { answer = i; break; }
  if (first.kind !== "user" || answer < 0) return group(turn, answer >= 0 ? turn[answer].id : null);
  const work = turn.filter((e, i) => i !== 0 && i !== answer && !isNotice(e));
  const notices: TranscriptRow[] = turn.filter(isNotice).map((e) => ({ kind: "notice", id: "notice:" + e.id, entry: e }));
  const final: TranscriptRow = { kind: "answer", id: "answer:" + turn[answer].id, entry: turn[answer], final: true };
  const user: TranscriptRow = { kind: "user", id: "user:" + first.id, entry: first };
  if (!work.length) return [user, ...notices, final];
  const end = Math.max(...turn.map((e) => e.date));
  return [user, { kind: "fold", id: "fold:" + work[0].id, seconds: end > first.date ? end - first.date : null, rows: group(work, null) }, ...notices, final];
}

function open(turn: TimelineEntry[]): TranscriptRow[] {
  const rows: TranscriptRow[] = [];
  let work = turn;
  if (turn[0]?.kind === "user") {
    rows.push({ kind: "user", id: "user:" + turn[0].id, entry: turn[0] });
    work = turn.slice(1);
  }
  rows.push({ kind: "working", id: "working", since: turn[0]?.kind === "user" ? turn[0].date : null });
  let current: TimelineEntry | null = null;
  const last = work[work.length - 1];
  if (last && last.kind === "tool") {
    current = last;
    work = work.slice(0, -1);
  }
  rows.push(...group(work, null), { kind: "live", id: "live", entry: current });
  return rows;
}

function group(entries: TimelineEntry[], finalId: string | null): TranscriptRow[] {
  const rows: TranscriptRow[] = [];
  let steps: TimelineEntry[] = [];
  const flush = () => {
    if (steps.length) rows.push({ kind: "work", id: "work:" + steps[0].id, steps });
    steps = [];
  };
  for (const e of entries) {
    if (e.kind === "tool" || e.kind === "change") steps.push(e);
    else {
      flush();
      if (isNotice(e)) rows.push({ kind: "notice", id: "notice:" + e.id, entry: e });
      else if (e.kind === "assistant") rows.push({ kind: "answer", id: "answer:" + e.id, entry: e, final: e.id === finalId });
      else rows.push({ kind: "user", id: "user:" + e.id, entry: e });
    }
  }
  flush();
  return rows;
}

/** "45s", "1m", "1m 3s", "2h", "2h 5m". */
export function duration(seconds: number): string {
  const total = Math.round(seconds);
  if (total < 60) return `${total}s`;
  if (total < 3600) return total % 60 === 0 ? `${Math.floor(total / 60)}m` : `${Math.floor(total / 60)}m ${total % 60}s`;
  const minutes = Math.floor((total % 3600) / 60);
  return minutes === 0 ? `${Math.floor(total / 3600)}h` : `${Math.floor(total / 3600)}h ${minutes}m`;
}

export type ToolKind = "command" | "edit" | "read" | "search" | "other";

export function toolKind(tool: string): ToolKind {
  switch (tool.toLowerCase()) {
    case "bash": case "shell": case "run_shell_command": case "nook terminal": case "killshell": case "bashoutput": return "command";
    case "edit": case "multiedit": case "write": case "notebookedit": case "write_file": case "replace": case "apply_patch": return "edit";
    case "read": case "read_file": case "read_many_files": case "ls": case "list_directory": case "notebookread": return "read";
    case "grep": case "glob": case "search_file_content": case "websearch": case "webfetch": case "web_search": case "web_fetch": case "google_web_search": return "search";
    default: return "other";
  }
}

/** "GitHub › Create issue" for `mcp__github__create_issue` (`McpToolLabel`). */
export function mcpLabel(raw: string): string | null {
  if (!raw.startsWith("mcp__")) return null;
  const parts = raw.slice(5).split("__");
  const tool = parts[parts.length - 1];
  if (parts.length < 2 || !tool) return null;
  let server = parts.slice(0, -1).join("__");
  if (server.startsWith("claude_ai_") && server.length > 10) server = server.slice(10);
  if (!server) return null;
  return readable(server) + " › " + readable(tool);
}

function readable(name: string): string {
  const words: string[] = [];
  let current = "";
  for (const c of name) {
    if ("_-./:".includes(c)) {
      if (current) words.push(current);
      current = "";
    } else if (c !== c.toLowerCase() && current && /[a-z0-9]$/.test(current)) {
      words.push(current);
      current = c;
    } else current += c;
  }
  if (current) words.push(current);
  return words
    .map((w, i) => (w.length > 1 && w === w.toUpperCase() ? w : i === 0 ? w.slice(0, 1).toUpperCase() + w.slice(1).toLowerCase() : w.toLowerCase()))
    .join(" ");
}

/** How a step reads: a verb, then what it did that to, and whether that is code (`TranscriptStepText`). */
export function stepParts(step: TimelineEntry): { verb: string; detail: string; mono: boolean } {
  const tool = step.detail ?? "";
  const summary = step.text;
  if (step.kind === "change") return { verb: tr("Bewerkte", "Edited"), detail: summary, mono: true };
  switch (tool) {
    case "Task": case "Agent": return { verb: tr("Delegeerde", "Delegated"), detail: summary, mono: false };
    case "TodoWrite": case "Plan": case "update_plan": return { verb: tr("Werkte de takenlijst bij", "Updated the task list"), detail: "", mono: false };
    case "ExitPlanMode": return { verb: tr("Stelde een plan voor", "Proposed a plan"), detail: "", mono: false };
    case "WebSearch": case "web_search": case "google_web_search": return { verb: tr("Zocht op het web", "Searched the web"), detail: summary, mono: false };
    case "WebFetch": case "web_fetch": return { verb: tr("Haalde op", "Fetched"), detail: summary, mono: true };
    case "Skill": return { verb: tr("Gebruikte skill", "Used skill"), detail: summary, mono: true };
  }
  const name = tool.toLowerCase();
  switch (toolKind(tool)) {
    case "command": return { verb: tr("Voerde uit", "Ran"), detail: summary, mono: true };
    case "edit": return { verb: name === "write" || name === "write_file" ? tr("Schreef", "Wrote") : tr("Bewerkte", "Edited"), detail: summary, mono: true };
    case "read": return { verb: name === "ls" || name === "list_directory" ? tr("Bekeek", "Listed") : tr("Gelezen", "Read"), detail: summary, mono: true };
    case "search": return { verb: tr("Zocht", "Searched"), detail: summary, mono: true };
    default: return { verb: tool ? (mcpLabel(tool) ?? tool) : summary, detail: tool ? summary : "", mono: false };
  }
}

/** A step's icon (`TranscriptSymbols`). */
export function stepIcon(step: TimelineEntry): string {
  const tool = step.detail ?? "";
  if (step.kind === "change") return "square-pen";
  switch (tool) {
    case "Task": case "Agent": return "users";
    case "TodoWrite": case "Plan": case "update_plan": case "ExitPlanMode": return "list-checks";
    case "WebSearch": case "WebFetch": case "web_search": case "web_fetch": case "google_web_search": return "globe";
    case "Skill": return "sparkles";
  }
  return kindIcon(toolKind(tool), tool.startsWith("mcp"));
}

function kindIcon(kind: ToolKind, mcp = false): string {
  switch (kind) {
    case "command": return "terminal";
    case "edit": return "square-pen";
    case "read": return "eye";
    case "search": return "search";
    default: return mcp ? "puzzle" : "wrench";
  }
}

/** What a run of steps did (`ToolTally`): the two most important kinds, then how many other actions; edits count files. */
export function tally(steps: TimelineEntry[]): { sentence: string; icon: string; failed: boolean } {
  const counts = new Map<ToolKind, number>();
  const files = new Set<string>();
  let failed = false;
  for (const s of steps) {
    if (s.failed) failed = true;
    const kind: ToolKind = s.kind === "change" ? "edit" : toolKind(s.detail ?? "");
    if (kind === "edit") files.add(s.text);
    else counts.set(kind, (counts.get(kind) ?? 0) + 1);
  }
  if (files.size) counts.set("edit", files.size);
  const parts = (["command", "edit", "read", "search", "other"] as ToolKind[]).filter((k) => counts.has(k)).map((k) => ({ kind: k, count: counts.get(k)! }));
  const icon = parts.length === 1 ? kindIcon(parts[0].kind) : "hammer";
  if (!parts.length) return { sentence: capital(phrase("other", 0)), icon, failed };
  const named = parts.slice(0, 2).map((p) => phrase(p.kind, p.count));
  const rest = parts.slice(2).reduce((n, p) => n + p.count, 0);
  const text = rest > 0
    ? tr("{a}, {b} en nog {n} acties", "{a}, {b} and {n} more actions", { a: named[0], b: named[1], n: rest })
    : named.length === 2 ? tr("{a} en {b}", "{a} and {b}", { a: named[0], b: named[1] }) : named[0];
  return { sentence: capital(text), icon, failed };
}

const capital = (t: string) => t.slice(0, 1).toUpperCase() + t.slice(1);

function phrase(kind: ToolKind, n: number): string {
  switch (kind) {
    case "command": return n === 1 ? tr("1 commando uitgevoerd", "Ran 1 command") : tr("{n} commando's uitgevoerd", "Ran {n} commands", { n });
    case "edit": return n === 1 ? tr("1 bestand gewijzigd", "changed 1 file") : tr("{n} bestanden gewijzigd", "changed {n} files", { n });
    case "read": return n === 1 ? tr("1 bestand gelezen", "read 1 file") : tr("{n} bestanden gelezen", "read {n} files", { n });
    case "search": return n === 1 ? tr("1 keer gezocht", "searched 1 time") : tr("{n} keer gezocht", "searched {n} times", { n });
    default: return n === 1 ? tr("1 andere actie", "1 other action") : tr("{n} andere acties", "{n} other actions", { n });
  }
}
