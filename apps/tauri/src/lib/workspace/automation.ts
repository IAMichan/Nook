// Automation: scheduled tasks and their webhooks, the switches in Settings › Agents › Automation, and handing a
// session to another agent. The shapes match nook_core::workspace::{schedule, scheduler}; the logic lives in Rust.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { tr } from "../i18n.svelte";
import type { PermissionPolicy, RunProvider } from "./api";

export type ScheduleRule =
  | { type: "interval"; seconds: number }
  | { type: "fixedTime"; hour: number; minute: number; weekdays: number[] }
  | { type: "webhook" }
  | { type: "once"; at: string }
  /** As soon as a new message arrives that matches (`workspace::arrivals::MessageTrigger`). */
  | { type: "message"; trigger: MessageTrigger };

export interface MessageTrigger {
  apps: string[];
  from: string;
  keywords: string[];
  groups: boolean;
}

export type ScheduledTaskTarget =
  | { type: "newSession"; projectPath: string; provider: RunProvider; profileId: string | null }
  | { type: "existingSession"; id: string; fresh: boolean }
  /** Nook Chat answers each run itself, in a conversation of its own (`schedule_task` from the chat). */
  | { type: "nook" };

export type ScheduledRunStatus = "running" | "succeeded" | "failed" | "skipped";

export interface ScheduledTask {
  id: string;
  title: string;
  prompt: string;
  rule: ScheduleRule;
  target: ScheduledTaskTarget;
  enabled: boolean;
  permission: PermissionPolicy;
  lastRun: string | null;
  lastStatus: ScheduledRunStatus | null;
  lastError: string | null;
  nextRun: string | null;
  lastSession: string | null;
  createdAt: string;
  /** For Nook: only speak up when something new needs the user. */
  quiet?: boolean;
  /** The ready-made task this is (the secretary's). */
  preset?: string | null;
  /** For Nook: what each run carries out by itself (`workspace::autonomy`). */
  autonomy?: NookAutonomy;
}

export type NookAutonomy = "ask" | "decide" | "auto";

/** The levels with their name and what they mean, as the Mac's editor shows them. */
export function autonomyLevels(): { id: NookAutonomy; label: string; detail: string }[] {
  return [
    { id: "ask", label: tr("Vraag mij", "Ask me"), detail: tr("Nook zet antwoorden, afspraken en andere stappen klaar; elke stap wacht op jouw klik.", "Nook prepares replies, appointments and other steps; each one waits for your click.") },
    { id: "decide", label: tr("Nook beslist", "Nook decides"), detail: tr("Nook voert wat duidelijk routine is zelf uit (een kort antwoord aan wie schreef, een herinnering) en laat de rest voor jou staan, met een korte reden.", "Nook carries out what is clearly routine by itself (a quick reply to someone who wrote, a reminder) and leaves the rest for you, with a short reason.") },
    { id: "auto", label: tr("Gewoon doen", "Do it"), detail: tr("Nook verstuurt de berichten en mail die het klaarzette en voert de wijzigingen zelf uit. Jij leest achteraf alleen wat het deed.", "Nook sends the messages and mail it prepared and makes the changes by itself. You only read afterwards what it did.") },
  ];
}

/** The short label for an autonomous level ("Nook decides" / "Do it"); null for "ask" so ordinary tasks stay quiet. */
export function autonomyLabel(level?: NookAutonomy | null): string | null {
  if (!level || level === "ask") return null;
  return autonomyLevels().find((l) => l.id === level)?.label ?? null;
}

/** Whether a task may run now: Nook's own non-webhook tasks run on their own switch; agent sessions and webhooks wait
 *  for the global "Allow scheduled tasks" switch (`ScheduledTask::may_run` in Rust). */
export function mayRunTask(task: Pick<ScheduledTask, "target" | "rule">, globalEnabled: boolean): boolean {
  return globalEnabled || (task.target.type === "nook" && task.rule.type !== "webhook");
}

export interface TaskView extends ScheduledTask {
  running: boolean;
  webhookUrl: string | null;
  sessionTitle: string | null;
}

export interface AutomationSettings {
  scheduledTasks: boolean;
  webhookPort: number;
  autoTitles: boolean;
  /** Your own rules for titles, given to the brain with every title it writes. */
  titleInstructions?: string;
}

export interface AutomationOverview {
  settings: AutomationSettings;
  tasks: TaskView[];
  listening: number | null;
  listenerError: string | null;
}

export type RunNow = "started" | "busy" | "notAvailable";

export const automationApi = {
  overview: () => invoke<AutomationOverview>("automation_overview"),
  saveSettings: (settings: AutomationSettings) => invoke<void>("automation_save_settings", { settings }),
  saveTask: (task: ScheduledTask) => invoke<ScheduledTask>("automation_save_task", { task }),
  deleteTask: (task: string) => invoke<void>("automation_delete_task", { task }),
  setEnabled: (task: string, enabled: boolean) => invoke<void>("automation_set_task_enabled", { task, enabled }),
  addSecretary: () => invoke<number>("automation_add_secretary"),
  runNow: (task: string) => invoke<RunNow>("automation_run_task", { task }),
  secret: (task: string, rotate = false) => invoke<string>("automation_webhook_secret", { task, rotate }),
  handOff: (run: string, provider: RunProvider, profileId: string, model = "") =>
    invoke<{ included: number; omitted: number; resumed: boolean }>("workspace_hand_off", { run, provider, profileId, model }),
  onChanged: (f: () => void): Promise<UnlistenFn> => listen("automation-changed", f),
};

/** The shortest interval, as in Rust (`MINIMUM_INTERVAL_SECONDS`). */
export const MINIMUM_INTERVAL_MINUTES = 1;

/** 1 = Sunday … 7 = Saturday, like the Mac; shown from Monday. */
export const weekdayOrder = [2, 3, 4, 5, 6, 7, 1];

export function weekdayShort(day: number): string {
  // 2024-01-07 was a Sunday.
  const date = new Date(2024, 0, 6 + day);
  return date.toLocaleDateString(undefined, { weekday: "short" });
}

const pad = (n: number) => String(n).padStart(2, "0");

/** The simple choices of the editor, like the Mac: every N minutes, every day or some weekdays at a time, once, webhook. */
export type Preset = "interval" | "daily" | "weekdays" | "once" | "webhook" | "message";

type EditorValues = { minutes: number; time: string; weekdays: number[]; at: string; apps?: string; from?: string; keywords?: string; groups?: boolean };

/** A comma-separated field as a list. */
function list(text: string): string[] {
  return text.split(",").map((s) => s.trim()).filter(Boolean);
}

export function presetOf(rule: ScheduleRule): Preset {
  if (rule.type === "fixedTime") return rule.weekdays.length ? "weekdays" : "daily";
  return rule.type;
}

/** The rule for a preset with the editor's values. Weekdays without a day chosen run Monday to Friday. */
export function ruleFor(preset: Preset, v: EditorValues): ScheduleRule {
  const [h, m] = v.time.split(":").map((x) => Number(x));
  const hour = Number.isFinite(h) ? h : 9;
  const minute = Number.isFinite(m) ? m : 0;
  switch (preset) {
    case "interval":
      return { type: "interval", seconds: Math.max(MINIMUM_INTERVAL_MINUTES, Math.round(v.minutes || 0)) * 60 };
    case "daily":
      return { type: "fixedTime", hour, minute, weekdays: [] };
    case "weekdays":
      return { type: "fixedTime", hour, minute, weekdays: v.weekdays.length ? [...v.weekdays].sort() : [2, 3, 4, 5, 6] };
    case "once":
      return { type: "once", at: new Date(v.at).toISOString() };
    case "webhook":
      return { type: "webhook" };
    case "message":
      return { type: "message", trigger: { apps: list(v.apps ?? "").map((a) => a.toLowerCase()), from: (v.from ?? "").trim(), keywords: list(v.keywords ?? ""), groups: !!v.groups } };
  }
}

/** What the editor shows for a rule (the inverse of `ruleFor`). */
export function editorValues(rule: ScheduleRule): Required<EditorValues> {
  const out: Required<EditorValues> = { minutes: 60, time: "09:00", weekdays: [], at: localInput(new Date(Date.now() + 3600_000)), apps: "", from: "", keywords: "", groups: false };
  if (rule.type === "message") {
    out.apps = rule.trigger.apps.join(", ");
    out.from = rule.trigger.from;
    out.keywords = rule.trigger.keywords.join(", ");
    out.groups = rule.trigger.groups;
  }
  if (rule.type === "interval") out.minutes = Math.max(MINIMUM_INTERVAL_MINUTES, Math.round(rule.seconds / 60));
  if (rule.type === "fixedTime") {
    out.time = `${pad(rule.hour)}:${pad(rule.minute)}`;
    out.weekdays = [...rule.weekdays];
  }
  if (rule.type === "once") out.at = localInput(new Date(rule.at));
  return out;
}

/** A `datetime-local` value in local time. */
export function localInput(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

/** "Every 30 min after the previous run ends", "Every day at 09:00", "Mon, Fri at 09:00", "Once, …", "From a webhook". */
export function ruleLabel(rule: ScheduleRule): string {
  switch (rule.type) {
    case "interval":
      return tr("Elke {n} min nadat de vorige run klaar is", "Every {n} min after the previous run ends", { n: Math.round(rule.seconds / 60) });
    case "fixedTime": {
      const time = `${pad(rule.hour)}:${pad(rule.minute)}`;
      if (!rule.weekdays.length) return tr("Elke dag om {time}", "Every day at {time}", { time });
      const days = weekdayOrder.filter((d) => rule.weekdays.includes(d)).map(weekdayShort).join(", ");
      return tr("{days} om {time}", "{days} at {time}", { days, time });
    }
    case "once":
      return tr("Eén keer, {when}", "Once, {when}", { when: new Date(rule.at).toLocaleString() });
    case "webhook":
      return tr("Vanuit een webhook", "From a webhook");
    case "message": {
      const t = rule.trigger;
      const parts = [tr("Bij een nieuw bericht", "On a new message")];
      if (t.apps.length) parts.push(tr("in {apps}", "in {apps}", { apps: t.apps.join(", ") }));
      if (t.from) parts.push(tr("van {from}", "from {from}", { from: t.from }));
      if (t.keywords.length) parts.push(tr("over {words}", "about {words}", { words: t.keywords.join(", ") }));
      return parts.join(" ");
    }
  }
}

/** The text for a stored reason code; other errors are shown as they are. */
export function reasonLabel(reason: string | null): string | null {
  if (!reason) return null;
  const known: Record<string, string> = {
    "sched.skip.missed": tr("Gemist: meer dan 10 minuten te laat, dus overgeslagen.", "Missed: more than 10 minutes late, so it was skipped."),
    "sched.skip.overlap": tr("Overgeslagen: de vorige run liep nog.", "Skipped: the previous run was still going."),
    "sched.error.interrupted": tr("Onderbroken door een herstart van Nook.", "Interrupted by a restart of Nook."),
    "sched.error.noSession": tr("De sessie bestaat niet meer.", "The session no longer exists."),
    "sched.error.badTarget": tr("De taak heeft geen geldige map of agent.", "The task has no valid folder or agent."),
    "sched.error.noBrain": tr("Nook Chat heeft nog geen brein. Kies er een in Instellingen.", "Nook Chat has no brain yet. Choose one in Settings."),
    "sched.error.nookTimeout": tr("Nook Chat deed er te lang over; de run is gestopt.", "Nook Chat took too long; the run was stopped."),
    "sched.error.nookEmpty": tr("Nook Chat gaf geen antwoord. Open het gesprek om te zien waarom.", "Nook Chat gave no answer. Open the conversation to see why."),
    "sched.nook.nothingNew": tr("Niets nieuws dat jou nodig heeft.", "Nothing new that needs you."),
    "sched.error.webhookRights": tr(
      "Een webhook mag alleen naar een sessie die om toestemming vraagt: wat van buiten komt, krijgt niet de rechten die je die sessie gaf.",
      "A webhook may only go to a session that asks for approval: what comes from outside does not get the rights you gave that session.",
    ),
  };
  return known[reason] ?? reason;
}

export function statusLabel(status: ScheduledRunStatus | null): string {
  switch (status) {
    case "running":
      return tr("Bezig", "Running");
    case "succeeded":
      return tr("Gelukt", "Succeeded");
    case "failed":
      return tr("Mislukt", "Failed");
    case "skipped":
      return tr("Overgeslagen", "Skipped");
    default:
      return tr("Nog niet gedraaid", "Not run yet");
  }
}

/** What is wrong with the editor's values, or null. */
export function problem(task: { prompt: string; rule: ScheduleRule; target: ScheduledTaskTarget }, now = Date.now()): string | null {
  if (!task.prompt.trim()) return tr("Schrijf een prompt.", "Write a prompt.");
  if (task.target.type === "newSession" && !task.target.projectPath.trim()) return tr("Kies een projectmap.", "Choose a project folder.");
  if (task.target.type === "existingSession" && !task.target.id) return tr("Kies de sessie waar de runs heen gaan.", "Choose the session the runs go to.");
  if (task.rule.type === "once" && !(new Date(task.rule.at).getTime() > now)) return tr("Kies een moment in de toekomst.", "Choose a moment in the future.");
  if (task.rule.type === "interval" && !(task.rule.seconds >= 60)) return tr("Het interval is minstens 1 minuut.", "The interval is at least 1 minute.");
  return null;
}

/** A new task as the editor starts it. */
export function blankTask(projectPath: string, provider: RunProvider): ScheduledTask {
  return {
    id: crypto.randomUUID(),
    title: "",
    prompt: "",
    rule: { type: "fixedTime", hour: 9, minute: 0, weekdays: [] },
    target: { type: "newSession", projectPath, provider, profileId: null },
    enabled: true,
    permission: "ask",
    lastRun: null,
    lastStatus: null,
    lastError: null,
    nextRun: null,
    lastSession: null,
    createdAt: new Date().toISOString(),
  };
}

/** The curl command that signs a test delivery, for the webhook's help text (HMAC-SHA256 with openssl). */
export function curlExample(url: string): string {
  return [
    `body='{"hello":"nook"}'`,
    `sig=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$NOOK_SECRET" | sed 's/^.* //')`,
    `curl -X POST "${url}" -H "X-Hub-Signature-256: sha256=$sig" -H "X-Nook-Delivery: $(date +%s)" -H "Content-Type: application/json" -d "$body"`,
  ].join("\n");
}
