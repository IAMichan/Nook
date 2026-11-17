// Work Nook does on its own (`ScheduledTaskTarget.nook`) in the Nook tab: the Scheduled tab of the list, the bar over a
// run's conversation and the "Scheduled run" marker (`NookScheduledTasks.swift` on the Mac). Pure helpers, tested on
// their own; the views are `NookTasks.svelte` and `NookTaskBar.svelte`.
import { api } from "./api";
import { tr } from "./i18n.svelte";
import type { Target } from "./inbox";
import type { ConversationSummary } from "./types";
import { ruleLabel, type TaskView } from "./workspace/automation";

/** A once-task that has run: nothing more to do. */
export function isDone(task: TaskView): boolean {
  return task.rule.type === "once" && !!task.lastRun && task.lastStatus !== "running";
}

/** Nook's own tasks that match the search (by name and by what they ask), the next to run first. */
export function nookTasks(tasks: TaskView[], query = ""): TaskView[] {
  const needle = query.trim().toLowerCase();
  return tasks
    .filter((t) => t.target.type === "nook")
    .filter((t) => !needle || t.title.toLowerCase().includes(needle) || t.prompt.toLowerCase().includes(needle))
    .sort((a, b) => {
      const at = a.nextRun ? Date.parse(a.nextRun) : Infinity;
      const bt = b.nextRun ? Date.parse(b.nextRun) : Infinity;
      return at - bt || a.title.localeCompare(b.title);
    });
}

/** Tasks that will run first; paused and finished ones under a label of their own. */
export function splitTasks(tasks: TaskView[]): { active: TaskView[]; resting: TaskView[] } {
  return { active: tasks.filter((t) => t.enabled && !isDone(t)), resting: tasks.filter((t) => !t.enabled || isDone(t)) };
}

/** What a task is doing, in one line: "Running…", "Paused", "Done", "next Tue 09:00". */
export function taskStatus(task: TaskView, now = new Date()): string {
  if (task.running) return tr("Bezig…", "Running…");
  if (!task.enabled) return tr("Gepauzeerd", "Paused");
  if (isDone(task)) return tr("Klaar", "Done");
  if (task.nextRun) return tr("volgende {when}", "next {when}", { when: upcoming(new Date(task.nextRun), now) });
  return "";
}

/** The schedule, then the status: "Every day at 09:00 · next Tue 09:00". */
export function taskDetail(task: TaskView, now = new Date()): string {
  return [ruleLabel(task.rule), taskStatus(task, now)].filter(Boolean).join(" · ");
}

/** A moment to come, short: the time today, the weekday and time this week, else the date. */
export function upcoming(date: Date, now = new Date()): string {
  const time = date.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  const sameDay = date.toDateString() === now.toDateString();
  if (sameDay) return time;
  const days = (date.getTime() - now.getTime()) / 86_400_000;
  if (days < 7) return `${date.toLocaleDateString(undefined, { weekday: "short" })} ${time}`;
  return `${date.toLocaleDateString(undefined, { day: "numeric", month: "short" })} ${time}`;
}

/** The conversation of a task's latest run, newest first in the list; none before its first run. */
export function latestRun(taskId: string, nooks: ConversationSummary[]): ConversationSummary | undefined {
  return nooks.filter((n) => n.scheduledTask === taskId).sort((a, b) => Date.parse(b.updated) - Date.parse(a.updated))[0];
}

/** The Scheduled tab's badge: an amber count of the runs that wait for your approval, or a dot while a run left an
 *  answer you have not read. */
export function tabBadge(tasks: TaskView[], nooks: ConversationSummary[]): { waiting: number; fresh: boolean } {
  const runs = nookTasks(tasks).map((t) => latestRun(t.id, nooks)?.status).filter(Boolean);
  return { waiting: runs.filter((s) => s === "waiting").length, fresh: runs.includes("unread") };
}

/** Opens Settings › Agents › Automation, where a task is edited: through the shell when it gave a way, else the way
 *  messages open Settings (`MessageView`). */
export function openAutomationSettings(onopen?: (target: Target) => void) {
  if (onopen) return onopen({ kind: "settings", section: "automation" });
  try { localStorage.setItem("settings.section", "automation"); } catch { /* opens on the last page instead */ }
  api.showMain("settings");
  window.dispatchEvent(new CustomEvent("nook-navigate", { detail: "settings" }));
}
