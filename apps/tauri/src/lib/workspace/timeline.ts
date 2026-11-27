// Hoe de tijdlijn van een sessie leest (TimelinePresentation, TimelineSearch, TimelineContainers, FailureJump,
// PlanPreview en ContextMeter op de Mac): een afgeronde beurt vouwt tot "2m 13s gewerkt" tussen jouw bericht en het
// antwoord, tool-aanroepen achter elkaar worden één regel ("3 commando's uitgevoerd en 2 bestanden gewijzigd"), en
// terwijl de agent werkt zegt één levende regel wat hij doet en denkt. Geen interface-code, zodat tests het los gebruiken.
import type { RunEvent } from "./api";
import { tr } from "../i18n.svelte";

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

function phrase(c: ToolCategory, n: number): string {
  const one = n === 1;
  switch (c) {
    case "command": return one ? tr("1 commando uitgevoerd", "Ran 1 command") : tr("{n} commando's uitgevoerd", "Ran {n} commands", { n });
    case "edit": return one ? tr("1 bestand gewijzigd", "changed 1 file") : tr("{n} bestanden gewijzigd", "changed {n} files", { n });
    case "read": return one ? tr("1 bestand gelezen", "read 1 file") : tr("{n} bestanden gelezen", "read {n} files", { n });
    case "search": return one ? tr("1 keer gezocht", "searched once") : tr("{n} keer gezocht", "searched {n} times", { n });
    case "other": return one ? tr("1 andere actie", "1 other action") : tr("{n} andere acties", "{n} other actions", { n });
  }
}

/// "3 commando's uitgevoerd en 2 bestanden gewijzigd": de twee belangrijkste soorten, dan hoeveel acties nog meer.
export function sentence(t: ToolTally): string {
  const p = parts(t);
  if (p.length === 0) return tr("{n} andere acties", "{n} other actions", { n: 0 });
  const named = p.slice(0, 2).map((x) => phrase(x.category, x.count));
  const rest = p.slice(2).reduce((s, x) => s + x.count, 0);
  if (rest > 0) return tr("{a}, {b} en nog {n} acties", "{a}, {b} and {n} more actions", { a: named[0], b: named[1], n: rest });
  return named.length === 2 ? tr("{a} en {b}", "{a} and {b}", { a: named[0], b: named[1] }) : named[0];
}

export type TimelineBlock =
  | { type: "event"; id: string; event: RunEvent }
  | { type: "tools"; id: string; events: RunEvent[]; tally: ToolTally }
  | { type: "fold"; id: string; seconds: number; blocks: TimelineBlock[] };

export interface LiveActivity {
  tool: string | null;
  thought: string | null;
}

// ============================================================================
// AG-73: Subagents, Background Commands, Wake Turns & Agent Progress
// ============================================================================

const SUBAGENT_TOOLS = new Set([
  "task",
  "agent",
  "invoke_subagent",
  "delegate_task",
  "spawn_agent",
  "subagent",
  "mcp__nook__delegate_task",
  "mcp__nook__session_start",
]);

export function isSubagentTool(name: string): boolean {
  const lower = name.trim().toLowerCase();
  if (SUBAGENT_TOOLS.has(lower)) return true;
  if (lower.startsWith("mcp__") && (lower.endsWith("__delegate_task") || lower.endsWith("__invoke_subagent") || lower.endsWith("__spawn_agent"))) {
    return true;
  }
  return false;
}

function parseInput(detail: string | undefined): Record<string, unknown> {
  if (!detail) return {};
  try {
    const o = JSON.parse(detail);
    return o && typeof o === "object" && !Array.isArray(o) ? (o as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/// The event is a subagent the agent started (not a nested call of a subagent's own, which starts with "↳").
export function isSubagentLaunch(e: RunEvent): boolean {
  return e.kind === "tool" && !!e.tool && isSubagentTool(e.tool) && !e.text.startsWith("↳");
}

/// The subagent was started with `run_in_background`: its call returns at once, and it ends later.
export function isBackgroundSubagent(e: RunEvent): boolean {
  if (!isSubagentLaunch(e) || !e.detail || !e.detail.includes("run_in_background")) return false;
  return parseInput(e.detail).run_in_background === true;
}

export function isSubagentLaunchNote(output: string | undefined): boolean {
  return !!output && output.trimStart().startsWith("Async agent launched");
}

export function subagentTaskId(output: string | undefined): string | null {
  if (!output || !isSubagentLaunchNote(output)) return null;
  const idx = output.indexOf("agentId: ");
  if (idx < 0) return null;
  const rest = output.slice(idx + "agentId: ".length);
  const match = rest.match(/^([^\s,)]+)/);
  return match?.[1] || null;
}

export interface SubagentInfo {
  id: string;
  kind: string;
  title: string;
  prompt: string;
  state?: RunEvent["state"];
  output?: string;
  background: boolean;
  started: string;
  taskId: string | null;
  isRunning: boolean;
  failed: boolean;
  answer: string | null;
}

export function subagentFromEvent(e: RunEvent): SubagentInfo | null {
  if (!isSubagentLaunch(e)) return null;
  const input = parseInput(e.detail);
  const subagentsArr = Array.isArray(input.Subagents) ? (input.Subagents as Record<string, unknown>[]) : null;
  const firstSub = subagentsArr && subagentsArr.length > 0 && typeof subagentsArr[0] === "object" ? subagentsArr[0] : null;
  const rawKind =
    (typeof input.subagent_type === "string" && input.subagent_type) ||
    (typeof input.TypeName === "string" && input.TypeName) ||
    (firstSub && typeof firstSub.TypeName === "string" && firstSub.TypeName) ||
    (typeof input.agent === "string" && input.agent) ||
    "agent";
  const rawTitle =
    (typeof input.description === "string" && input.description) ||
    (typeof input.Role === "string" && input.Role) ||
    (firstSub && typeof firstSub.Role === "string" && firstSub.Role) ||
    (typeof input.title === "string" && input.title) ||
    e.text.replace(/^(?:Task|Agent|invoke_subagent)\s*·\s*/i, "");
  const rawPrompt =
    (typeof input.prompt === "string" && input.prompt) ||
    (typeof input.Prompt === "string" && input.Prompt) ||
    (firstSub && typeof firstSub.Prompt === "string" && firstSub.Prompt) ||
    (typeof input.task === "string" && input.task) ||
    "";
  const isRunning = !e.state || e.state === "running" || e.state === "pending";
  const failed = e.state === "failed" || e.state === "denied" || e.state === "expired";
  const out = e.output?.trim() ?? "";
  const answer = !isRunning && out && !isSubagentLaunchNote(out) ? out : null;
  return {
    id: e.id,
    kind: rawKind.trim() || "agent",
    title: rawTitle.trim() || e.text,
    prompt: rawPrompt,
    state: e.state,
    output: e.output,
    background: input.run_in_background === true,
    started: e.date,
    taskId: subagentTaskId(e.output),
    isRunning,
    failed,
    answer,
  };
}

export function listSubagents(events: RunEvent[]): SubagentInfo[] {
  const out: SubagentInfo[] = [];
  for (const e of events) {
    const info = subagentFromEvent(e);
    if (info) out.push(info);
  }
  return out;
}

/// Subagents started since the user's last message (wake turns belong to the same work), plus any earlier ones still running.
export function currentSubagents(events: RunEvent[]): SubagentInfo[] {
  const start = Math.max(0, findLastIndex(events, (e) => e.kind === "user"));
  const recent = listSubagents(events.slice(start));
  const earlier = listSubagents(events.slice(0, start)).filter((a) => a.isRunning);
  return [...earlier, ...recent];
}

export function subagentSignature(agents: SubagentInfo[]): string {
  return agents.map((a) => `${a.id}${a.isRunning ? "+" : "-"}`).join(",");
}

/// Whether a tool call asks to run in the background (`run_in_background`) and is not a subagent launch.
export function asksBackgroundCommand(e: RunEvent): boolean {
  if (e.kind !== "tool" || isSubagentLaunch(e) || e.text.startsWith("↳")) return false;
  if (!e.detail || !e.detail.includes("run_in_background")) return false;
  return parseInput(e.detail).run_in_background === true;
}

export function isBackgroundCommandNote(output: string | undefined): boolean {
  if (!output) return false;
  const t = output.trimStart();
  return (
    t.startsWith("Command running in background with ID:") ||
    (t.startsWith("Command did not complete within") && t.includes("moved to the background"))
  );
}

/// Whether `e` is a command left running in the background.
export function isBackgroundCommand(e: RunEvent): boolean {
  if (e.kind !== "tool" || isSubagentLaunch(e) || e.text.startsWith("↳")) return false;
  if ((e as RunEvent & { background?: boolean }).background === true) return true;
  if (asksBackgroundCommand(e)) return true;
  if (isBackgroundCommandNote(e.output)) return true;
  const lowerTool = (e.tool ?? "").toLowerCase();
  if (lowerTool === "monitor" || lowerTool.startsWith("monitor ") || lowerTool.endsWith("__monitor")) return true;
  return false;
}

export function extractCommandText(e: RunEvent): string {
  const input = parseInput(e.detail);
  for (const k of ["command", "CommandLine", "cmd", "script"]) {
    if (typeof input[k] === "string" && (input[k] as string).trim()) return (input[k] as string).trim();
  }
  const stripped = e.text.replace(/^[^·]+·\s*/, "").trim();
  return stripped || e.detail || e.text;
}

export function stripBackgroundLaunchNote(output: string | undefined): string | null {
  if (!output) return null;
  let text = output.trim();
  if (!text) return null;
  if (
    text.startsWith("Command running in background with ID:") ||
    (text.startsWith("Command did not complete within") && text.includes("moved to the background"))
  ) {
    const marker = "Read on that file path";
    const idx = text.indexOf(marker);
    if (idx < 0) {
      const notifyIdx = text.indexOf("You will be notified when it completes.");
      if (notifyIdx < 0) return null;
      text = text.slice(notifyIdx + "You will be notified when it completes.".length).replace(/^[.\s]+/, "");
    } else {
      text = text.slice(idx + marker.length).replace(/^[.\s]+/, "");
    }
  }
  return text.trim() || null;
}

export function backgroundCommandOutputFile(output: string | undefined): string | null {
  if (!output) return null;
  const m = output.match(/Output is being written to:\s*([^\s]+?)(?:\.\s|\.$|\s|$)/);
  return m?.[1] ?? null;
}

export interface BackgroundCommandInfo {
  id: string;
  title: string;
  command: string;
  state?: RunEvent["state"];
  output?: string;
  started: string;
  isRunning: boolean;
  failed: boolean;
  printed: string | null;
  outputFile: string | null;
}

export function backgroundCommandFromEvent(e: RunEvent): BackgroundCommandInfo | null {
  if (!isBackgroundCommand(e)) return null;
  const input = parseInput(e.detail);
  const command = extractCommandText(e);
  const desc = typeof input.description === "string" && input.description.trim() ? input.description.trim() : null;
  const isRunning = !e.state || e.state === "running" || e.state === "pending";
  const failed = e.state === "failed" || e.state === "denied" || e.state === "expired";
  return {
    id: e.id,
    title: desc ?? oneLine(command, 120),
    command,
    state: e.state,
    output: e.output,
    started: e.date,
    isRunning,
    failed,
    printed: stripBackgroundLaunchNote(e.output),
    outputFile: backgroundCommandOutputFile(e.output),
  };
}

export function listBackgroundCommands(events: RunEvent[]): BackgroundCommandInfo[] {
  const out: BackgroundCommandInfo[] = [];
  for (const e of events) {
    const info = backgroundCommandFromEvent(e);
    if (info) out.push(info);
  }
  return out;
}

/// Commands started since the user's last message, plus any earlier ones still running (`BackgroundCommands.current` on macOS).
export function currentBackgroundCommands(events: RunEvent[]): BackgroundCommandInfo[] {
  const start = Math.max(0, findLastIndex(events, (e) => e.kind === "user"));
  const recent = listBackgroundCommands(events.slice(start));
  const earlier = listBackgroundCommands(events.slice(0, start)).filter((c) => c.isRunning);
  return [...earlier, ...recent];
}

/// Running first, then failed, then completed; newest first within each group (`BackgroundCommands.ordered` on macOS).
export function orderedBackgroundCommands(commands: BackgroundCommandInfo[]): BackgroundCommandInfo[] {
  const rank = (c: BackgroundCommandInfo) => (c.isRunning ? 0 : c.failed ? 1 : 2);
  return commands
    .map((item, index) => ({ item, index }))
    .sort((a, b) => (rank(a.item) !== rank(b.item) ? rank(a.item) - rank(b.item) : b.index - a.index))
    .map((x) => x.item);
}

export function backgroundCommandSignature(commands: BackgroundCommandInfo[]): string {
  return commands.map((c) => `${c.id}${c.isRunning ? "+" : "-"}`).join(",");
}

export function backgroundCommandTail(text: string | null | undefined, maxLines = 4): string | null {
  if (!text) return null;
  const lines = text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  if (!lines.length) return null;
  return lines.slice(-maxLines).join("\n");
}

const NOTICE_CHUNK_RE =
  /^\s*([\w.-]+) has been (?:launched|started) in the background\.?(?:\s*I will wait for it to (?:complete|finish) before proceeding\.?)?\s*/i;

/// Antigravity background launch notice ("task-148 has been launched in the background. I will wait for it to complete before proceeding.").
export function backgroundLaunchNotice(text: string): string[] {
  if (!text || text.length > 2000) return [];
  const tasks: string[] = [];
  let rest = text;
  while (rest.length > 0) {
    const m = rest.match(NOTICE_CHUNK_RE);
    if (!m || !m[0]) return [];
    tasks.push(m[1]);
    rest = rest.slice(m[0].length);
  }
  return tasks;
}

export function isBackgroundNotice(e: RunEvent): boolean {
  return e.kind === "assistant" && backgroundLaunchNotice(e.text).length > 0;
}

/// Where the agent woke up by itself after background work ended (`TimelinePresentation.isWake` on macOS).
export function isWake(e: RunEvent): boolean {
  return e.kind === "system" && e.tool === "wake";
}

export function isNews(e: RunEvent): boolean {
  return e.kind === "system" && e.tool === "prwatch";
}

export function isSessionChange(e: RunEvent): boolean {
  return e.kind === "system" && !!e.tool && ["switch", "handoff", "resume", "clear"].includes(e.tool);
}

/// Whether `e` is a foreground tool call the agent is actively waiting on right now (`TimelinePresentation.isLive` on macOS).
export function isLiveTool(e: RunEvent): boolean {
  return e.kind === "tool" && e.state === "running" && !isBackgroundSubagent(e) && !isBackgroundCommand(e);
}

/// Splits a session's timeline into turns. Wake turns (`system` with `tool === "wake"`) join onto the preceding user turn
/// so consecutive wake turns / subagent wakeups fold and read as one coherent piece of work alongside the user's request,
/// while a wake event at the very start of a timeline or after a session change starts a turn if none exists yet.
export function split(events: RunEvent[]): RunEvent[][] {
  const turns: RunEvent[][] = [];
  let ended = false;
  for (const e of events) {
    if (e.kind === "user" || turns.length === 0 || (ended && (isNews(e) || isSessionChange(e)))) {
      turns.push([e]);
      ended = false;
    } else if (isWake(e)) {
      // Join wake turns into the current turn so subagent / background command wakeups don't fragment the turn.
      turns[turns.length - 1].push(e);
      ended = false;
    } else {
      turns[turns.length - 1].push(e);
    }
    if (e.kind === "result") ended = true;
  }
  return turns;
}

/// The last turn of `split` (resolves across PR news turns that start after a finished turn, #1601).
export function lastTurn(events: RunEvent[]): RunEvent[] {
  const turns = split(events);
  return turns[turns.length - 1] ?? [];
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
  const answer = findLastIndex(turn, (e) => e.kind === "assistant" && !isBackgroundNotice(e));
  // Alleen een beurt die goed afliep vouwt: het antwoord blijft staan, het werk ertussen gaat dicht.
  if (open || (first.kind !== "user" && !isNews(first)) || !finished || troubled || answer < 0) return group(turn);
  // A card the agent put up for you (a suggested session, a page) stays in sight under the answer, never in the fold.
  const card = (e: RunEvent) => e.kind === "system" && (e.tool === "session_suggestion" || e.tool === "render_page");
  // Drop intermediate `result` events from joined wake turns inside the fold while keeping the final `finished` result.
  const work = turn.filter((e, i) => i !== 0 && i !== answer && e.kind !== "result" && !card(e) && !isWake(e));
  const cards = turn.filter(card).map(ev);
  if (!work.some((e) => e.kind !== "assistant" || isBackgroundNotice(e))) return group(turn);
  const seconds = Math.max(0, (Date.parse(finished.date) - Date.parse(first.date)) / 1000);
  // De vouw krijgt het id van het eerste werk dat hij verbergt: nooit hetzelfde als een blok ernaast.
  return [ev(first), { type: "fold", id: work[0].id, seconds, blocks: group(work) }, ev(turn[answer]), ...cards, ev(finished)];
}

/// Twee of meer tool-aanroepen achter elkaar worden één blok. Subagent-starts krijgen altijd hun eigen rij (`!isSubagentLaunch`),
/// en gedachten of achtergrond-meldingen (`isBackgroundNotice`) tussen twee tools vouwen mee in de groep.
export function group(events: RunEvent[]): TimelineBlock[] {
  const out: TimelineBlock[] = [];
  let run: RunEvent[] = [];
  const isWork = (e: RunEvent) => (e.kind === "tool" && !isSubagentLaunch(e)) || e.kind === "fileChange";
  const flush = () => {
    const leading: RunEvent[] = [];
    while (run.length && !isWork(run[0])) leading.push(run.shift()!);
    const trailing: RunEvent[] = [];
    while (run.length && !isWork(run[run.length - 1])) trailing.unshift(run.pop()!);
    out.push(...leading.filter((e) => !isWake(e)).map(ev));
    if (run.filter(isWork).length >= 2) out.push({ type: "tools", id: run[0].id, events: run, tally: tally(run) });
    else out.push(...run.map(ev));
    out.push(...trailing.filter((e) => !isWake(e)).map(ev));
    run = [];
  };
  for (const e of events) {
    if (isWake(e)) continue;
    if (isWork(e) || (run.length > 0 && isBackgroundNotice(e))) {
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
  const tool =
    findLast(turn, isLiveTool) ??
    findLast(turn, (e) => e.kind === "tool" && !isBackgroundSubagent(e) && !isBackgroundCommand(e));
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

/// "< 1 min", "12 min", "2h 5m", "3 d" (AgentPathFormat.duration).
export function duration(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  if (minutes < 1) return "< 1 min";
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return minutes % 60 === 0 ? tr("{h}u", "{h}h", { h: hours }) : tr("{h}u {m}m", "{h}h {m}m", { h: hours, m: minutes % 60 });
  return `${Math.floor(hours / 24)} d`;
}
