// The plan-limits card on the empty chat (the Mac's `GlanceLimitsCard`): per signed-in account, its fullest window,
// what you would run out of first, with the Mac's tones (amber from 75%, coral from 90%).
import type { AgentProfile, PlanUsage, PlanWindow } from "./agents";

export interface GlanceLimit {
  id: string;
  /// "Claude", or "Claude · Work" when several accounts of one agent report.
  name: string;
  window: "5h" | "week";
  used: number;
}

export type Tone = "calm" | "warning" | "error";

export function tone(used: number): Tone {
  return used >= 90 ? "error" : used >= 75 ? "warning" : "calm";
}

/// A window that has already reset counts as empty.
function effective(w: PlanWindow, now: number): number {
  return Date.parse(w.resetsAt) <= now ? 0 : Math.round(w.usedPercent);
}

/// The fullest window of each account that reports one: per profile where known, else the main account as "claude".
export function glanceLimits(
  main: PlanUsage | null | undefined,
  perProfile: Record<string, PlanUsage>,
  profiles: AgentProfile[],
  now = Date.now(),
): GlanceLimit[] {
  const entries: [string, PlanUsage][] = Object.keys(perProfile).length ? Object.entries(perProfile) : main ? [["claude", main]] : [];
  const kinds = new Map<string, number>();
  for (const [id] of entries) {
    const kind = profiles.find((p) => p.id === id)?.kind ?? "claude";
    kinds.set(kind, (kinds.get(kind) ?? 0) + 1);
  }
  const limits: GlanceLimit[] = [];
  for (const [id, usage] of entries) {
    const windows: [GlanceLimit["window"], PlanWindow | null][] = [["5h", usage.fiveHour], ["week", usage.sevenDay]];
    const fullest = windows
      .filter((w): w is [GlanceLimit["window"], PlanWindow] => !!w[1])
      .map(([window, w]) => ({ window, used: effective(w, now) }))
      .sort((a, b) => b.used - a.used)[0];
    if (!fullest) continue;
    const profile = profiles.find((p) => p.id === id);
    const agent = profile?.kind === "codex" ? "Codex" : profile?.kind === "gemini" ? "Gemini" : "Claude";
    const several = (kinds.get(profile?.kind ?? "claude") ?? 0) > 1;
    const name = several && profile?.label ? `${agent} · ${profile.label}` : agent;
    limits.push({ id, name, window: fullest.window, used: fullest.used });
  }
  return limits.sort((a, b) => b.used - a.used);
}
