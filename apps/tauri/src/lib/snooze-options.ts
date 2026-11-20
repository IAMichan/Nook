// The snooze options every snooze menu offers (the Mac's `SnoozeOption` and Settings › Notifications ›
// `SnoozeOptionsSection`): durations ("1 hour") and times of day ("this evening at 18:00", "Monday at 09:00"), set by
// you, kept for every window in localStorage. Pure, so the times are tested.
import { locale, tr } from "./i18n.svelte";

export type SnoozeDay = "today" | "tomorrow" | "monday" | "tuesday" | "wednesday" | "thursday" | "friday" | "saturday" | "sunday";
export type SnoozeOption =
  | { kind: "duration"; minutes: number }
  | { kind: "time"; day: SnoozeDay; hour: number; minute: number };

export const SNOOZE_KEY = "nook.snoozeOptions";
export const DEFAULT_OPTIONS: SnoozeOption[] = [
  { kind: "duration", minutes: 60 },
  { kind: "time", day: "today", hour: 18, minute: 0 },
  { kind: "time", day: "tomorrow", hour: 9, minute: 0 },
];
/// A month, the longest a duration may be; at most this many options in a menu.
export const MAX_MINUTES = 30 * 24 * 60;
export const MAX_COUNT = 8;
const WEEKDAYS: SnoozeDay[] = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];

export const optionId = (o: SnoozeOption) => (o.kind === "duration" ? `d${o.minutes}` : `t-${o.day}-${o.hour}-${o.minute}`);

/// When the snooze ends if chosen at `now`; null for a today option whose time has passed (the menu hides it).
export function snoozeEnd(o: SnoozeOption, now: Date): Date | null {
  if (o.kind === "duration") return o.minutes > 0 ? new Date(now.getTime() + Math.min(o.minutes, MAX_MINUTES) * 60_000) : null;
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  if (o.day === "tomorrow") d.setDate(d.getDate() + 1);
  else if (o.day !== "today") {
    const ahead = (WEEKDAYS.indexOf(o.day) - now.getDay() + 7) % 7;
    d.setDate(d.getDate() + (ahead === 0 ? 7 : ahead));
  }
  d.setHours(Math.min(Math.max(o.hour, 0), 23), Math.min(Math.max(o.minute, 0), 59), 0, 0);
  return d > now ? d : null;
}

/// The options a menu shows at `now`: the ones still ahead, soonest first, each end once.
export function snoozeMenu(options: SnoozeOption[], now: Date): { option: SnoozeOption; end: Date }[] {
  const seen = new Set<number>();
  return options
    .map((option) => ({ option, end: snoozeEnd(option, now) }))
    .filter((x): x is { option: SnoozeOption; end: Date } => !!x.end)
    .sort((a, b) => a.end.getTime() - b.end.getTime())
    .filter((x) => !seen.has(x.end.getTime()) && !!seen.add(x.end.getTime()));
}

/// Valid options only, each once, at most `MAX_COUNT`; none left falls back to the defaults.
export function cleaned(options: unknown): SnoozeOption[] {
  const list = Array.isArray(options) ? (options as SnoozeOption[]) : [];
  const seen = new Set<string>();
  const valid = list.filter((o) => {
    if (!o || typeof o !== "object") return false;
    const ok = o.kind === "duration"
      ? Number.isInteger(o.minutes) && o.minutes >= 1 && o.minutes <= MAX_MINUTES
      : o.kind === "time" && [...WEEKDAYS, "today", "tomorrow"].includes(o.day) && o.hour >= 0 && o.hour <= 23 && o.minute >= 0 && o.minute <= 59;
    return ok && !seen.has(optionId(o)) && !!seen.add(optionId(o));
  });
  return valid.length ? valid.slice(0, MAX_COUNT) : DEFAULT_OPTIONS;
}

export function loadOptions(): SnoozeOption[] {
  try { return cleaned(JSON.parse(localStorage.getItem(SNOOZE_KEY) ?? "null")); } catch { return DEFAULT_OPTIONS; }
}

export function saveOptions(options: SnoozeOption[]) {
  try { localStorage.setItem(SNOOZE_KEY, JSON.stringify(cleaned(options))); } catch { /* the defaults stay */ }
}

/// An option's name in a menu: "In 1 hour", "This evening, 18:00", "Monday, 09:00".
export function optionLabel(o: SnoozeOption): string {
  if (o.kind === "duration") {
    if (o.minutes % 1440 === 0) return tr("{n} dag(en)", "{n} day(s)", { n: o.minutes / 1440 });
    if (o.minutes % 60 === 0) return tr("Over {n} uur", "In {n} hour(s)", { n: o.minutes / 60 });
    return tr("Over {n} min", "In {n} min", { n: o.minutes });
  }
  const at = new Date(2024, 0, 1, o.hour, o.minute).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" });
  const day = o.day === "today"
    ? (o.hour >= 17 ? tr("Vanavond", "This evening") : tr("Vandaag", "Today"))
    : o.day === "tomorrow"
      ? (o.hour < 12 ? tr("Morgenochtend", "Tomorrow morning") : tr("Morgen", "Tomorrow"))
      : new Date(2024, 0, 7 + WEEKDAYS.indexOf(o.day)).toLocaleDateString(locale(), { weekday: "long" });
  return `${day}, ${at}`;
}
