// Agents: dezelfde vormen als de Rust-structs in nook_core::agents, en de aanroepen naar de Rust-kant.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type AgentKind = "claude" | "codex" | "gemini" | "antigravity" | "opencode" | "cursor" | "grok";
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
}

export type ApprovalDecision = "allow" | "always" | "deny" | "terminal";

export interface QuestionOption { label: string; description: string }
export interface QuestionItem { question: string; header: string; options: QuestionOption[]; multiSelect: boolean }
export interface QuestionRequest { id: string; sessionKey: string; agentName: string; project: string; items: QuestionItem[] }

export interface PlanWindow { usedPercent: number; resetsAt: string }
export interface PlanUsage { fiveHour: PlanWindow | null; sevenDay: PlanWindow | null; updated: string }

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

export interface AgentProfile {
  id: string;
  kind: AgentKind;
  label: string;
  home: string | null;
  auth: "cli" | "apiKey" | null;
  title: string;
  displayHome: string;
  preferred: boolean;
  hasKey: boolean;
  launchCommand: string;
  loginCommand: string;
}

export const agentApi = {
  overview: () => invoke<Overview>("agents_overview"),
  decide: (id: string, decision: ApprovalDecision) => invoke<void>("agents_decide", { id, decision }),
  decideInTerminal: (id: string) => invoke<void>("agents_decide_in_terminal", { id }),
  answer: (id: string, selections: string[][]) => invoke<void>("agents_answer", { id, selections }),
  answerInTerminal: (id: string) => invoke<void>("agents_answer_in_terminal", { id }),
  end: (sessionId: string) => invoke<void>("agents_end", { sessionId }),
  forget: (sessionId: string) => invoke<void>("agents_forget", { sessionId }),
  canEnd: (sessionId: string) => invoke<boolean>("agents_can_end", { sessionId }),
  transcript: (path: string) => invoke<ChatMessage[]>("agents_transcript", { path }),
  history: (force = false) => invoke<HistoryResult>("agents_history", { force }),
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
  markFinished: (key: string, finished: boolean) => invoke<void>("agents_mark_finished", { key, finished }),
  visit: (id: string, unread = false) => invoke<void>("agents_visit", { id, unread }),
  activateTerminal: (host: string) => invoke<void>("agents_activate_terminal", { host }),
  runInTerminal: (command: string, folder?: string) => invoke<void>("agents_run_in_terminal", { command, folder }),
  terminalName: (host: string) => invoke<string>("agents_terminal_name", { host }),
  sound: (kind: "attention" | "done" | "error") => invoke<string | null>("agents_sound", { kind }),
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
  onHistory: (cb: (h: HistoryResult) => void): Promise<UnlistenFn> => listen<HistoryResult>("agents-history", (e) => cb(e.payload)),
};

export const agentNames: Record<AgentKind, string> = {
  claude: "Claude Code", codex: "Codex", gemini: "Gemini CLI", antigravity: "Antigravity", opencode: "OpenCode", cursor: "Cursor", grok: "Grok",
};

export const agentColors: Record<AgentKind, string> = {
  claude: "#E08A5E", codex: "#6FCFB3", gemini: "#8AB4F8", antigravity: "#EA4335", opencode: "#F5A742", cursor: "#9AA4B2", grok: "#D9D9DE",
};

/// De kleur bij een weergavenaam ("Claude Code", "Codex", …).
export function colorFor(name: string): string {
  const kind = (Object.keys(agentNames) as AgentKind[]).find((k) => agentNames[k] === name || (name === "Claude (app)" && k === "claude"));
  return kind ? agentColors[kind] : "#9c9aa8";
}

export const statusLabels: Record<AgentStatus, string> = {
  detected: "gezien", waiting: "wacht op jou", running: "bezig", failed: "mislukt", done: "klaar",
};

/// "845k", "1,2M".
export function formatTokens(n: number): string {
  if (n < 1000) return String(n);
  if (n < 100_000) return (n / 1000).toFixed(1).replace(".", ",") + "k";
  if (n < 1_000_000) return Math.floor(n / 1000) + "k";
  return (n / 1_000_000).toFixed(1).replace(".", ",") + "M";
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
  if (u.fiveHour) parts.push(`5u ${Math.round(eff(u.fiveHour))}%`);
  if (u.sevenDay) parts.push(`week ${Math.round(eff(u.sevenDay))}%`);
  return parts.join(" · ");
}
