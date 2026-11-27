// Readiness, session advice, token savings, and agent tuning helpers + Tauri command wrappers
// (`AgentReadiness`, `AgentAdvice`, `TokenSavings`, `AgentTuning` on macOS — AG-32).
import { invoke } from "@tauri-apps/api/core";
import { tr } from "../i18n.svelte";
import type { RunProvider } from "./api";

export const DEFAULT_AUTO_COMPACT_TOKENS = 350_000;
export const SIZE_COMPACTION_CHOICES = [0, 150_000, 250_000, 350_000, 500_000] as const;

export type TuningKind =
  | "unusedPlugins"
  | "cloudConnectors"
  | "unusedServers"
  | "servers"
  | "longInstructions"
  | "autoCompactOff";

export interface TuningAdvice {
  id: string;
  provider: RunProvider;
  kind: TuningKind;
  items: string[];
  kept: string[];
  characters: number | null;
  tokens: number | null;
  location: string;
  snippet: string | null;
  appliesInNook: boolean;
}

export interface AppliedTuning {
  claudePlugins: string[];
  claudeNoConnectors: boolean;
}

export interface TuningSnapshot {
  rows: TuningAdvice[];
  applied: AppliedTuning;
  settingsFile: string;
  home: string;
}

export type ReadinessState = "checking" | "connecting" | "signIn" | "missing" | "ready";

export type ReadinessAction = "none" | "install" | "signIn";

export interface AgentReadinessItem {
  provider: RunProvider;
  state: ReadinessState;
  action: ReadinessAction;
}

export interface ProjectCandidate {
  path: string;
  name: string;
  parent: string;
  sessions: number;
  lastActive: string;
  added: boolean;
}

export interface ReadinessSnapshot {
  agents: AgentReadinessItem[];
  anyReady: boolean;
  projects: ProjectCandidate[];
}

export interface LimitSuggestion {
  provider: RunProvider;
  profileId: string;
  sameAgent: boolean;
  usedFraction: number | null;
  resumeIn: number | null;
}

export type StuckSuggestion =
  | { kind: "waitingOnYou"; minutes: number }
  | { kind: "noProgress"; minutes: number }
  | { kind: "limitedForLong"; minutes: number };

export interface RunAdviceSnapshot {
  options: LimitSuggestion[];
  fallbacks: LimitSuggestion[];
  stuck: StuckSuggestion | null;
}

const PROVIDER_DISPLAY_NAMES: Record<RunProvider, string> = {
  claude: "Claude Code",
  codex: "Codex",
  gemini: "Gemini CLI",
  opencode: "OpenCode",
  cursor: "Cursor",
  grok: "Grok",
  antigravity: "Antigravity",
};

export function providerDisplayName(provider: RunProvider): string {
  return PROVIDER_DISPLAY_NAMES[provider] ?? provider;
}

/** Replaces a leading home directory path with `~`, preserving both POSIX and Windows separators. */
export function formatTildePath(location: string, home?: string | null): string {
  if (!home || location.startsWith("https://") || location.startsWith("http://")) return location;
  const trimmedHome = home.replace(/[\\/]+$/, "");
  if (!trimmedHome) return location;
  if (location === trimmedHome) return "~";
  if (location.startsWith(trimmedHome + "/") || location.startsWith(trimmedHome + "\\")) {
    return "~" + location.slice(trimmedHome.length);
  }
  return location;
}

/** Mirrors `AppliedTuning::is_applied` on the frontend for immediate toggle state reflection. */
export function isAdviceApplied(applied: AppliedTuning, item: TuningAdvice): boolean {
  if (item.provider !== "claude") return false;
  if (item.kind === "unusedPlugins") {
    return item.items.length > 0 && item.items.every((p) => applied.claudePlugins.includes(p));
  }
  if (item.kind === "cloudConnectors") {
    return applied.claudeNoConnectors;
  }
  return false;
}

export function tuningKindTitle(kind: TuningKind): string {
  switch (kind) {
    case "unusedPlugins":
      return tr("Plugins die je niet gebruikt", "Plugins you do not use");
    case "cloudConnectors":
      return tr("claude.ai-connectors die je niet gebruikt", "claude.ai connectors you do not use");
    case "unusedServers":
      return tr("MCP-servers die je niet gebruikt", "MCP servers you do not use");
    case "servers":
      return tr("MCP-servers in elke sessie", "MCP servers in every session");
    case "longInstructions":
      return tr("Lange persoonlijke instructies", "Long personal instructions");
    case "autoCompactOff":
      return tr("Auto-compact staat uit", "Auto-compact is off");
  }
}

export function tuningKindWhy(kind: TuningKind): string {
  switch (kind) {
    case "unusedPlugins":
      return tr(
        "Hun skills en agents staan in elk verzoek, terwijl je er in 30 dagen geen gebruikte. Zet je ze uit, dan kun je een plugin weer aanzetten zodra je hem nodig hebt.",
        "Their skills and agents are listed in every request, though none was used in 30 days. Turned off, you can turn a plugin back on whenever you need it.",
      );
    case "cloudConnectors":
      return tr(
        "Hun toolnamen en instructies gaan mee in elke sessie. Claude Code zet ze alleen allemaal tegelijk uit; gebruik je er één, koppel dan de andere los op claude.ai.",
        "Their tool names and instructions go into every session. Claude Code turns them off all at once; when you use one of them, disconnect the others on claude.ai instead.",
      );
    case "unusedServers":
      return tr(
        "Hun tools laden in elke sessie, en geen sessie riep ze in 30 dagen aan.",
        "Their tools load into every session, and no session called them in 30 days.",
      );
    case "servers":
      return tr(
        "De tools van elke server gaan mee met elk verzoek. De agent houdt niet bij welke je gebruikt: zet uit wat je niet nodig hebt.",
        "Each server's tools go with every request. The agent keeps no record of which ones you use: turn off those you do not need.",
      );
    case "longInstructions":
      return tr(
        "Dit bestand gaat mee in elke sessie. Houd erin wat overal geldt; regels voor één project horen in het bestand van dat project.",
        "This file goes with every session. Keep in it what applies everywhere; project rules belong in the project's own file.",
      );
    case "autoCompactOff":
      return tr(
        "Een vol gesprek gaat dan bij elk verzoek opnieuw mee tot het venster vol is; met auto-compact vat de agent het eerst samen.",
        "A full conversation is then sent again with every request until the window runs out; with auto-compact the agent summarizes it first.",
      );
  }
}

/** Formats the multi-line detail block of a tuning suggestion row (matching macOS `TuningAdviceRow.detail`). */
export function tuningAdviceDetail(item: TuningAdvice, home?: string | null): string {
  const lines: string[] = [];
  if (item.items.length > 0 && item.kind !== "longInstructions") {
    lines.push(item.items.join(", "));
  }
  if (item.tokens != null) {
    lines.push(tr("Ongeveer {n} tokens per verzoek", "About {n} tokens per request", { n: item.tokens }));
  }
  if (item.kept.length > 0) {
    lines.push(tr("Blijft: {items}", "Stays: {items}", { items: item.kept.join(", ") }));
  }
  lines.push(tuningKindWhy(item.kind));
  lines.push(tr("Instelling: {where}", "Setting: {where}", { where: formatTildePath(item.location, home) }));
  return lines.join("\n");
}

export const tokenSavingsApi = {
  scanTuning: () => invoke<TuningSnapshot>("workspace_tuning_scan"),
  setTuning: (advice: TuningAdvice, on: boolean) => invoke<AppliedTuning>("workspace_tuning_set", { advice, on }),
  readiness: () => invoke<ReadinessSnapshot>("workspace_readiness"),
  limitAdvice: (run: string) => invoke<RunAdviceSnapshot>("workspace_limit_advice", { run }),
  offersCompactFirst: (run: string) => invoke<boolean>("workspace_offers_compact_first", { run }),
  revealPath: (path: string) => invoke<void>("workspace_reveal_path", { path }),
};
