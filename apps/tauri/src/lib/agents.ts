// Agents: dezelfde vormen als de Rust-structs in nook_core::agents, en de aanroepen naar de Rust-kant.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { locale, tr } from "./i18n.svelte";

export type AgentKind = "claude" | "codex" | "gemini" | "antigravity" | "opencode" | "cursor" | "grok" | "acp";
export type AgentStatus = "waiting" | "running" | "failed" | "done" | "detected";
export type StepMark = "done" | "running" | "blocked" | "failed" | "todo";
export type DiffKind = "add" | "remove" | "context";

export interface DiffLine { kind: DiffKind; text: string }
export interface AgentStep { mark: StepMark; text: string }

export interface AgentSession {
  id: string;
  name: string;
  project: string;
  status: AgentStatus;
  file: string;
  placeholder: string;
  steps: AgentStep[];
  diff: DiffLine[];
  cwd: string;
  host: string;
  home: string;
  approvalId: string | null;
  questionId: string | null;
  linesAdded: number;
  linesRemoved: number;
  summary: string;
  isLinked: boolean;
  sessionId: string;
  transcriptPath: string;
  lastPrompt: string;
  lastReply: string;
  started: string | null;
  updated: string | null;
  pid: number | null;
  /** The session whose shell started this one (`LaunchedSessions` on the Mac): an agent's test run or helper. */
  launchedBy?: string | null;
  /** True while the agent is compacting its conversation context (PreCompact → PostCompact / next event / 300s). */
  compacting?: boolean;
}

export interface GrantedRuleEntry {
  id: string;
  project: string;
  projectName: string;
  rule: string;
  reach: "project" | "sharedProject" | "user" | "session" | "agentDecides" | string;
  reachLabel: string;
  file: string;
  agent: string;
  grantedAt: string | null;
}

export type ApprovalSource = "app" | "notification" | "phone";

export interface ApprovalAuditEntry {
  id: string;
  timestamp: string;
  agent: string;
  project: string;
  projectPath: string;
  tool: string;
  summary: string;
  decision: "allow" | "always" | "deny" | "terminal" | "expired" | string;
  scope?: string | null;
  source?: ApprovalSource | null;
  danger: boolean;
  args: string;
  result: string;
}

export type ApprovalOrigin =
  | { kind: "hook"; requestId: string }
  | { kind: "run"; runId: string; requestId: string }
  | { kind: "bridge"; requestId: string };

export interface AgentApproval {
  id: string;
  origin: ApprovalOrigin;
  agentName: string;
  project: string;
  tool: string;
  title: string;
  command: string;
  diff: DiffLine[];
  note: string;
  danger: boolean;
  canAlways: boolean;
  canTerminal: boolean;
  sessionKey: string;
  created: string;
  /** What "Always" would allow and how far it reaches ("Always allows Bash(npm test:*) · this project"). */
  alwaysScope?: string | null;
}

export type ApprovalDecision = "allow" | "always" | "deny" | "terminal";

export interface QuestionOption { label: string; description: string; /** What the option would look like, in the code font. */ preview?: string }
export interface QuestionItem { question: string; header: string; options: QuestionOption[]; multiSelect: boolean }
export interface QuestionRequest { id: string; sessionKey: string; agentName: string; project: string; items: QuestionItem[]; restored?: boolean }

export interface PlanWindow { usedPercent: number; resetsAt: string }
export interface PlanUsage { fiveHour: PlanWindow | null; sevenDay: PlanWindow | null; updated: string }

export interface CodexWindow {
  usedPercent: number;
  resetsAt: string | null;
  windowMinutes: number | null;
}

export interface ResetCredits {
  available: number;
  nextExpiresAt: string | null;
}

export interface CodexUsage {
  fiveHour: CodexWindow | null;
  weekly: CodexWindow | null;
  planType: string | null;
  updated: string;
  resetCredits: ResetCredits | null;
}

export type ResetOutcome = "reset" | "nothingToReset" | "noCredit" | "alreadyRedeemed" | "failed";

export interface QuotaLimit {
  label: string;
  percent: number;
  resetsAt: string | null;
  note: string | null;
  durationSecs: number | null;
}

export interface AccountLimits {
  profileId: string;
  kind: AgentKind;
  name: string;
  email: string | null;
  plan: string;
  apiKey: boolean;
  usage: PlanUsage | null;
  codex: CodexUsage | null;
  antigravityLimits: QuotaLimit[];
  antigravityNoLogin: boolean;
  redeeming: boolean;
}

export type CliProxyProblem =
  | "noKey"
  | "badAddress"
  | "insecureAddress"
  | "rejectedKey"
  | "unreachable"
  | "notAHub";

export interface CliProxyHub {
  id: string;
  label: string;
  url: string;
}

export interface CliProxyWindow {
  key: "five_hour" | "seven_day" | "other" | string;
  usedPercent: number;
  resetsAt: string | null;
  durationSecs: number | null;
}

export interface CliProxyAccount {
  id: string;
  provider: string;
  agentKind: AgentKind | null;
  name: string;
  email: string | null;
  label: string;
  disabled: boolean;
  status: string;
  statusMessage: string | null;
  unavailable: boolean;
  available: boolean;
  retryAt: string | null;
  succeeded: number;
  failed: number;
  windows: CliProxyWindow[];
}

export interface CliProxyHubSnapshot {
  hub: CliProxyHub;
  name: string;
  accounts: CliProxyAccount[];
  readAt: string | null;
  problem: CliProxyProblem | null;
}

export interface CliProxyAddResult {
  problem: CliProxyProblem | null;
}

export interface Marks { finished: string[]; kept: Record<string, string>; visits: Record<string, string> }

export interface Overview {
  sessions: AgentSession[];
  approvals: AgentApproval[];
  questions: QuestionRequest[];
  planUsage: PlanUsage | null;
  profilePlanUsage: Record<string, PlanUsage>;
  marks: Marks;
}

export interface TokenTally { input: number; output: number; cacheRead: number; cacheWrite: number }

export interface PastSession {
  agent: AgentKind;
  sessionId: string;
  title: string;
  cwd: string;
  lastCwd: string;
  branch: string;
  model: string;
  started: string;
  ended: string;
  prompts: number;
  tokens: TokenTally;
  lastPrompt: string;
  lastReply: string;
  profileId: string;
  path: string;
}

export interface AgentAccount { agent: AgentKind; name: string; organization: string; plan: string }
export interface UsageSummary {
  today: TokenTally;
  week: TokenTally;
  sessionsToday: number;
  sessionsWeek: number;
  perDay: [string, number][];
}

export interface HistoryResult {
  sessions: PastSession[];
  accounts: Record<string, AgentAccount>;
  usage: Record<string, UsageSummary>;
  installed: AgentKind[];
  executables: Record<string, string>;
}

export interface ChatMessage { id: string; kind: "user" | "assistant" | "thinking"; text: string }

export type LinkTarget =
  | "claudeHooks" | "claudeStatusLine" | "codex" | "gemini" | "antigravity" | "cursor" | "copilot" | "muse" | "openCode" | "amp" | "hermes";
export type LinkState = { kind: "notInstalled" | "installed" | "outdated" } | { kind: "unreadable"; detail: string };

export interface Integration {
  target: LinkTarget;
  agent: AgentKind | null;
  profileId: string | null;
  title: string;
  detail: string;
  path: string;
  state: LinkState;
}

export interface LinkPreview { id: string; title: string; path: string; install: boolean; preview: DiffLine[]; unchanged: boolean }

export interface AccountVariable {
  name: string;
  value: string;
  sensitive: boolean;
}

export interface AgentProfile {
  id: string;
  kind: AgentKind;
  label: string;
  home: string | null;
  auth: "cli" | "apiKey" | null;
  disabled?: boolean | null;
  executablePath?: string | null;
  extraArguments?: string[] | null;
  variables?: AccountVariable[] | null;
  customModels?: string[] | null;
  title: string;
  displayHome: string;
  preferred: boolean;
  enabled: boolean;
  hasKey: boolean;
  homeVariable?: string | null;
  storedSecretVariables?: string[];
  launchCommand: string;
  loginCommand: string;
}

export const agentApi = {
  overview: () => invoke<Overview>("agents_overview"),
  decide: (id: string, decision: ApprovalDecision) => invoke<void>("agents_decide", { id, decision }),
  decideInTerminal: (id: string) => invoke<void>("agents_decide_in_terminal", { id }),
  /** "Deny with reason": the agent hears why it may not. */
  deny: (id: string, reason: string) => invoke<void>("agents_deny", { id, reason }),
  answer: (id: string, selections: string[][]) => invoke<void>("agents_answer", { id, selections }),
  answerInTerminal: (id: string) => invoke<void>("agents_answer_in_terminal", { id }),
  end: (sessionId: string) => invoke<void>("agents_end", { sessionId }),
  forget: (sessionId: string) => invoke<void>("agents_forget", { sessionId }),
  canEnd: (sessionId: string) => invoke<boolean>("agents_can_end", { sessionId }),
  transcript: (path: string) => invoke<ChatMessage[]>("agents_transcript", { path }),
  history: (force = false) => invoke<HistoryResult>("agents_history", { force }),
  limits: () => invoke<AccountLimits[]>("agents_limits"),
  usageRefresh: (manual = false) => invoke<void>("agents_usage_refresh", { manual }),
  codexUsage: () => invoke<Record<string, CodexUsage>>("agents_codex_usage"),
  useResetCredit: (profile: string, key: string) => invoke<ResetOutcome>("agents_use_reset_credit", { profile, key }),
  cliproxyHubs: () => invoke<CliProxyHubSnapshot[]>("agents_cliproxy_hubs"),
  cliproxyAdd: (label: string, address: string, key: string) =>
    invoke<CliProxyAddResult>("agents_cliproxy_add", { label, address, key }),
  cliproxyRemove: (id: string) => invoke<void>("agents_cliproxy_remove", { id }),
  cliproxyRefresh: (force = false) => invoke<void>("agents_cliproxy_refresh", { force }),
  integrations: () => invoke<Integration[]>("agents_integrations"),
  prepareLink: (target: LinkTarget, install: boolean, profileId: string | null) =>
    invoke<LinkPreview>("agents_prepare_link", { target, install, profileId }),
  applyLink: (id: string) => invoke<string | null>("agents_apply_link", { id }),
  discardLink: (id: string) => invoke<void>("agents_discard_link", { id }),
  profiles: () => invoke<AgentProfile[]>("agents_profiles"),
  addProfile: (kind: AgentKind, label: string) => invoke<AgentProfile>("agents_profile_add", { kind, label }),
  renameProfile: (id: string, label: string) => invoke<void>("agents_profile_rename", { id, label }),
  removeProfile: (id: string) => invoke<void>("agents_profile_remove", { id }),
  preferProfile: (id: string) => invoke<void>("agents_profile_prefer", { id }),
  setProfileAuth: (id: string, method: "cli" | "apiKey") => invoke<void>("agents_profile_auth", { id, method }),
  setProfileKey: (id: string, key: string) => invoke<boolean>("agents_profile_key", { id, key }),
  setProfileEnabled: (id: string, enabled: boolean) => invoke<void>("agents_profile_set_enabled", { id, enabled }),
  setProfileExecutablePath: (id: string, path: string) => invoke<void>("agents_profile_set_executable_path", { id, path }),
  setProfileExtraArguments: (id: string, argumentsList: string[]) =>
    invoke<void>("agents_profile_set_extra_arguments", { id, arguments: argumentsList }),
  setProfileVariables: (id: string, variables: AccountVariable[]) =>
    invoke<void>("agents_profile_set_variables", { id, variables }),
  setProfileCustomModels: (id: string, models: string[]) =>
    invoke<void>("agents_profile_set_custom_models", { id, models }),
  markFinished: (key: string, finished: boolean) => invoke<void>("agents_mark_finished", { key, finished }),
  visit: (id: string, unread = false) => invoke<void>("agents_visit", { id, unread }),
  activateTerminal: (host: string) => invoke<void>("agents_activate_terminal", { host }),
  runInTerminal: (command: string, folder?: string) => invoke<void>("agents_run_in_terminal", { command, folder }),
  terminalName: (host: string) => invoke<string>("agents_terminal_name", { host }),
  sound: (kind: "attention" | "permission" | "done" | "error") => invoke<string | null>("agents_sound", { kind }),
  grantedRules: (project?: string | null, extraProjects?: string[]) =>
    invoke<GrantedRuleEntry[]>("agents_granted_rules", { project: project || null, extraProjects: extraProjects ?? null }),
  revokeRule: (project: string, rule: string, file?: string | null) =>
    invoke<boolean>("agents_revoke_rule", { project, rule, file: file || null }),
  revokeProjectRules: (project: string) => invoke<number>("agents_revoke_project_rules", { project }),
  approvalAudit: (query?: string | null, limit?: number) =>
    invoke<ApprovalAuditEntry[]>("agents_approval_audit", { query: query || null, limit: limit ?? null }),
  clearApprovalAudit: () => invoke<void>("agents_clear_approval_audit"),
};

export interface Gone { id: string; message: string | null }

export const agentEvents = {
  onChanged: (cb: () => void): Promise<UnlistenFn> => listen("agents-changed", () => cb()),
  onApproval: (cb: (a: AgentApproval) => void): Promise<UnlistenFn> => listen<AgentApproval>("agent-approval", (e) => cb(e.payload)),
  onApprovalGone: (cb: (g: Gone) => void): Promise<UnlistenFn> => listen<Gone>("agent-approval-gone", (e) => cb(e.payload)),
  onQuestion: (cb: (q: QuestionRequest) => void): Promise<UnlistenFn> => listen<QuestionRequest>("agent-question", (e) => cb(e.payload)),
  onQuestionGone: (cb: (g: Gone) => void): Promise<UnlistenFn> => listen<Gone>("agent-question-gone", (e) => cb(e.payload)),
  onAttention: (cb: (s: AgentSession) => void): Promise<UnlistenFn> => listen<AgentSession>("agent-attention", (e) => cb(e.payload)),
  onUsage: (cb: () => void): Promise<UnlistenFn> => listen("agent-usage", () => cb()),
  onCliProxy: (cb: () => void): Promise<UnlistenFn> => listen("cliproxy-usage", () => cb()),
  onCodexUsage: (cb: (map: Record<string, CodexUsage>) => void): Promise<UnlistenFn> =>
    listen<Record<string, CodexUsage>>("codex-usage", (e) => cb(e.payload)),
  onHistory: (cb: (h: HistoryResult) => void): Promise<UnlistenFn> => listen<HistoryResult>("agents-history", (e) => cb(e.payload)),
};

export const agentNames: Record<AgentKind, string> = {
  claude: "Claude Code", codex: "Codex", gemini: "Gemini CLI", antigravity: "Antigravity", opencode: "OpenCode", cursor: "Cursor", grok: "Grok", acp: "ACP",
};

export const agentColors: Record<AgentKind, string> = {
  claude: "#E08A5E", codex: "#6FCFB3", gemini: "#8AB4F8", antigravity: "#EA4335", opencode: "#F5A742", cursor: "#9AA4B2", grok: "#D9D9DE", acp: "#B59CF5",
};

/// De kleur bij een weergavenaam ("Claude Code", "Codex", …).
export function colorFor(name: string): string {
  const kind = (Object.keys(agentNames) as AgentKind[]).find((k) => agentNames[k] === name || (name === "Claude (app)" && k === "claude"));
  return kind ? agentColors[kind] : "#9c9aa8";
}

/// Read through getters, so each read is in the current interface language.
export const statusLabels: Record<AgentStatus, string> = {
  get detected() { return tr("gezien", "seen"); },
  get waiting() { return tr("wacht op jou", "waiting for you"); },
  get running() { return tr("bezig", "working"); },
  get failed() { return tr("mislukt", "failed"); },
  get done() { return tr("klaar", "done"); },
};

/// "845k", "1,2M".
export function formatTokens(n: number): string {
  if (n < 1000) return String(n);
  const one = (x: number) => x.toLocaleString(locale(), { minimumFractionDigits: 1, maximumFractionDigits: 1 });
  if (n < 100_000) return one(n / 1000) + "k";
  if (n < 1_000_000) return Math.floor(n / 1000) + "k";
  return one(n / 1_000_000) + "M";
}

export function total(t: TokenTally): number {
  return t.input + t.output + t.cacheRead + t.cacheWrite;
}

/// "5u 34% · week 12%"
export function planLabel(u: PlanUsage | null | undefined): string {
  if (!u) return "";
  const now = Date.now();
  const eff = (w: PlanWindow) => (new Date(w.resetsAt).getTime() <= now ? 0 : w.usedPercent);
  const parts: string[] = [];
  if (u.fiveHour) parts.push(tr("5u {n}%", "5h {n}%", { n: Math.round(eff(u.fiveHour)) }));
  if (u.sevenDay) parts.push(tr("week {n}%", "week {n}%", { n: Math.round(eff(u.sevenDay)) }));
  return parts.join(" · ");
}

/// The agent's own usage page, where the plan's usage is managed and extra usage bought; null when it has none.
export function usagePageUrl(kind: AgentKind): string | null {
  if (kind === "claude") return "https://claude.ai/settings/usage";
  if (kind === "codex") return "https://chatgpt.com/codex/settings/usage";
  return null;
}

/// Compact countdown ("3d 4u", "2u 14m", "42m", "< 1m") matching `AgentFormat.compactDuration` on the Mac.
export function formatCompactDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  if (s < 60) return "< 1m";
  const mins = Math.floor(s / 60);
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  const remMins = mins % 60;
  if (hours < 24) {
    return remMins > 0
      ? tr("{h}u {m}m", "{h}h {m}m", { h: hours, m: remMins })
      : tr("{h}u", "{h}h", { h: hours });
  }
  const days = Math.floor(hours / 24);
  const remHours = hours % 24;
  return remHours > 0
    ? tr("{d}d {h}u", "{d}d {h}h", { d: days, h: remHours })
    : `${days}d`;
}

/// Upcoming reset clock time ("15:30", "tomorrow 15:30", "Thu 17:30") matching `AgentFormat.upcoming` on the Mac.
export function formatUpcomingTime(date: Date, now: Date = new Date()): string {
  const loc = locale();
  const time = date.toLocaleTimeString(loc, { hour: "2-digit", minute: "2-digit", hour12: false });
  const sameDay = (a: Date, b: Date) =>
    a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  if (sameDay(date, now)) return time;
  const tomorrow = new Date(now);
  tomorrow.setDate(tomorrow.getDate() + 1);
  if (sameDay(date, tomorrow)) return `${tr("morgen", "tomorrow")} ${time}`;
  const diffDays = (date.getTime() - now.getTime()) / 86_400_000;
  if (diffDays > 0 && diffDays < 6) {
    const weekday = date.toLocaleDateString(loc, { weekday: "short" });
    return `${weekday} ${time}`;
  }
  const day = date.toLocaleDateString(loc, { day: "numeric", month: "short" });
  return `${day} ${time}`;
}

