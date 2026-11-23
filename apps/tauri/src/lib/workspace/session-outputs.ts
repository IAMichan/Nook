// What a session produced that is worth looking at next to the conversation (`SessionOutputs`, `SharedFiles` and
// `ArtifactHistory` on the Mac, AG-102): the agent's task list, the plans it proposed, and the files it wrote that are made
// to be seen (a design as HTML or SVG, a document in Markdown, a PDF, an image, a video). All of it comes from the session's
// own events; code it changed stays in the changes view. No interface code, so tests use it on their own.
import type { RunEvent } from "./api";
import type { TaskStep } from "../task-steps";
import { categoryOf, pathOf, planTitle } from "./timeline";

export type OutputKind = "tasks" | "plan" | "design" | "document" | "pdf" | "image" | "video";

export interface SessionOutput {
  id: string;
  kind: OutputKind;
  title: string;
  /** The file, for a design, a document, an image …: an absolute path. */
  path: string | null;
  /** A plan's Markdown. */
  text?: string;
  steps?: TaskStep[];
  /** Milliseconds since the epoch. */
  date: number;
  /** The agent handed the file over on purpose (`SendUserFile`) the last time it touched it. */
  shared: boolean;
}

/** What a file is, by its extension; null for everything else (code, configuration, data). */
export function outputKind(path: string): Exclude<OutputKind, "tasks" | "plan"> | null {
  const ext = (path.split(/[\\/]/).pop() ?? "").split(".").pop()?.toLowerCase() ?? "";
  if (["html", "htm", "svg"].includes(ext)) return "design";
  if (["md", "markdown", "mdx"].includes(ext)) return "document";
  if (ext === "pdf") return "pdf";
  if (["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].includes(ext)) return "image";
  if (["mp4", "mov", "m4v", "webm"].includes(ext)) return "video";
  return null;
}

const isAbsolute = (p: string) => p.startsWith("/") || /^[A-Za-z]:[\\/]/.test(p) || p.startsWith("\\\\");

/** An absolute path for one the agent named relative to its folder. */
export function resolveOutputPath(path: string, directory: string | null | undefined): string {
  const trimmed = path.trim();
  if (isAbsolute(trimmed) || !directory) return trimmed;
  const sep = directory.includes("\\") && !directory.includes("/") ? "\\" : "/";
  const parts = (directory.replace(/[\\/]+$/, "") + sep + trimmed).split(/[\\/]/);
  const out: string[] = [];
  for (const p of parts.slice(1)) {
    if (p === "" || p === ".") continue;
    if (p === "..") out.pop();
    else out.push(p);
  }
  return parts[0] + sep + out.join(sep);
}

const shortName = (tool: string) => (tool.startsWith("mcp__") ? (tool.split("__").pop() ?? tool) : tool);
/** The tools that hand files over, by name (an MCP tool by its own name); Codex's generated pictures count too. */
const SHARE_TOOLS = new Set(["SendUserFile", "image_generation"]);

function input(event: RunEvent): Record<string, unknown> {
  try {
    const o = JSON.parse(event.detail ?? "");
    return o && typeof o === "object" ? (o as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** The files of a hand-over call, as the agent named them (`files`, or one `file` or `path`). */
export function sharedPaths(args: Record<string, unknown>): string[] {
  const listed = Array.isArray(args.files) ? args.files : [args.file, args.path];
  return listed.filter((x): x is string => typeof x === "string").map((x) => x.trim()).filter(Boolean);
}

/** A call that handed files over (and did not fail). */
export const isShare = (e: RunEvent) =>
  e.kind === "tool" && e.state !== "failed" && SHARE_TOOLS.has(shortName(e.tool ?? "")) && sharedPaths(input(e)).length > 0;

/** What the agent said with a hand-over. */
export function sharedCaption(args: Record<string, unknown>): string | null {
  return typeof args.caption === "string" && args.caption.trim() ? args.caption : null;
}

const TASK_TOOLS = new Set(["TodoWrite", "update_plan", "Plan", "todo_write", "todowrite", "write_todos"]);
const stepStatus = (raw: unknown): TaskStep["status"] =>
  raw === "completed" || raw === "done" ? "done"
    : raw === "in_progress" || raw === "inProgress" || raw === "running" || raw === "active" ? "active"
    : raw === "cancelled" || raw === "canceled" ? "cancelled" : "pending";

/** A task list a tool call sets: Claude Code's TodoWrite (`todos`), Codex's update_plan (`plan`), or the same shapes. */
export function taskList(tool: string, args: Record<string, unknown>): TaskStep[] | null {
  if (!TASK_TOOLS.has(shortName(tool))) return null;
  if (Array.isArray(args.todos)) {
    return args.todos.flatMap((t: Record<string, unknown>) => {
      const state = stepStatus(t.status);
      const text = (state === "active" && typeof t.activeForm === "string" && t.activeForm) || t.content || t.description;
      return typeof text === "string" && text ? [{ text, status: state }] : [];
    });
  }
  if (Array.isArray(args.plan)) {
    return args.plan.map((s: Record<string, unknown>, i: number) => ({ text: String(s.step ?? "").trim() || `Step ${i + 1}`, status: stepStatus(s.status) }));
  }
  return null;
}

/** A session's outputs, newest first: its task list (`tasks`, the one it keeps now, else the last one it wrote), every plan
 *  it proposed, and each file worth seeing once, at the last time it was written. */
export function collectOutputs(events: RunEvent[], tasks: TaskStep[] | null | undefined, directory: string | null | undefined): SessionOutput[] {
  const outputs: SessionOutput[] = [];
  const files = new Map<string, number>();
  let latestTasks: { steps: TaskStep[]; date: number } | null = null;
  const when = (e: RunEvent) => Date.parse(e.date) || 0;
  const add = (raw: string, date: number, shared = false) => {
    const path = resolveOutputPath(raw, directory);
    const kind = path ? outputKind(path) : null;
    if (!path || !kind) return;
    const output: SessionOutput = { id: "file:" + path, kind, title: path.split(/[\\/]/).pop() ?? path, path, date, shared };
    const at = files.get(path);
    if (at !== undefined) outputs[at] = output;
    else { files.set(path, outputs.length); outputs.push(output); }
  };
  for (const e of events) {
    if (e.rolledBack) continue;
    if (e.kind === "assistant" && e.tool === "plan") {
      outputs.push({ id: "plan:" + e.id, kind: "plan", title: planTitle(e.text) ?? "", path: null, text: e.text, date: when(e), shared: false });
    } else if (e.kind === "tool" && isShare(e)) {
      for (const p of sharedPaths(input(e))) add(p, when(e), true);
    } else if (e.kind === "tool") {
      const args = input(e);
      const steps = taskList(e.tool ?? "", args);
      if (steps) latestTasks = { steps, date: when(e) };
      else if (categoryOf(e.tool ?? "") === "edit" && e.state !== "failed") {
        const path = pathOf(e.detail);
        if (path) add(path, when(e));
      }
    } else if (e.kind === "fileChange" && e.tool !== "deleted") {
      add(e.detail ?? e.text, when(e));
    }
  }
  const steps = tasks && tasks.length ? tasks : latestTasks?.steps;
  if (steps) {
    const last = events[events.length - 1];
    outputs.push({ id: "tasks", kind: "tasks", title: "", path: null, steps, date: latestTasks?.date ?? (last ? when(last) : Date.now()), shared: false });
  }
  return outputs.sort((a, b) => b.date - a.date);
}

/** Whether a new output of this turn (made at or after `turnStart`) opens the outputs tab by itself while the agent works.
 *  A plan, design, PDF, image or video does; a Markdown document only when the agent handed it over, because one it merely
 *  writes or edits (a README, notes) is part of its work. The task list never does; it has its own strip. */
export function opensByItself(o: SessionOutput, turnStart: number | null): boolean {
  if (turnStart === null || o.date < turnStart) return false;
  if (o.kind === "tasks") return false;
  if (o.kind === "document") return o.shared;
  return true;
}

/** Changes when an output does: a file written again, a list that moved on. */
export const outputSignature = (o: SessionOutput) => (o.kind === "tasks" ? "tasks:" + (o.steps ?? []).map((s) => s.status).join(",") : `${o.id}@${o.date}`);

/** Something new since `seen` (the outputs you last looked at), for the dot on the panel's button. */
export const hasNewOutput = (outputs: SessionOutput[], seen: Set<string>) => outputs.some((o) => !seen.has(outputSignature(o)));
