// De werkruimte: dezelfde vormen als de Rust-structs in nook_core::workspace, en de aanroepen naar de Rust-kant.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type RunProvider = "claude" | "codex" | "gemini" | "opencode" | "cursor" | "grok" | "antigravity";
export type ExecutionMode = "agent" | "plan";
export type PermissionPolicy = "ask" | "acceptEdits" | "bypass";
export type IsolationMode = "folder" | "worktree";
export type RunStatus = "preparing" | "running" | "waitingApproval" | "completed" | "failed" | "stopped";
export type EventKind = "user" | "assistant" | "thinking" | "tool" | "fileChange" | "approval" | "error" | "system" | "result";
export type EventState = "running" | "done" | "failed" | "pending" | "allowed" | "denied" | "expired";

export interface RunUsage {
  inputTokens: number | null;
  outputTokens: number | null;
  cacheReadTokens: number | null;
  cacheWriteTokens: number | null;
  reportedCostUsd: number | null;
  contextTokens: number | null;
  contextWindow: number | null;
  turns: number;
  activeSeconds: number;
}

export interface WorkspaceRun {
  id: string;
  title: string;
  task: string;
  provider: RunProvider;
  profileId: string;
  model: string;
  resolvedModel: string | null;
  mode: ExecutionMode;
  permission: PermissionPolicy;
  isolation: IsolationMode;
  projectPath: string;
  workingDirectory: string;
  repoRoot: string | null;
  branch: string | null;
  baseBranch: string | null;
  worktreePath: string | null;
  instructions: string;
  status: RunStatus;
  statusDetail: string | null;
  providerSessionId: string | null;
  createdAt: string;
  updatedAt: string;
  archived: boolean;
  usage: RunUsage;
  turnStartedAt: string | null;
  reviewedAt: string | null;
  lastChangeAt: string | null;
  changedFiles: number | null;
  checkpoints: { ref: string; date: string }[];
  limitedAt: string | null;
  limitResetAt: string | null;
  autoResume: boolean;
  effort: string | null;
}

export interface RunEvent {
  id: string;
  date: string;
  kind: EventKind;
  text: string;
  tool?: string;
  callId?: string;
  detail?: string;
  output?: string;
  state?: EventState;
}

export interface QueuedMessage { id: string; text: string; createdAt: string; edited: boolean }
export interface MessageQueue { messages: QueuedMessage[]; isHeld: boolean }

export interface ProviderCapabilities {
  approvals: boolean;
  interrupt: boolean;
  streamingText: boolean;
  planMode: boolean;
  reportsCost: boolean;
  reportsContextWindow: boolean;
  reportsCacheTokens: boolean;
  policies: PermissionPolicy[];
  steering: boolean;
  nativeFork: boolean;
}

export interface ProviderInfo {
  provider: RunProvider;
  name: string;
  capabilities: ProviderCapabilities;
  executable: string | null;
  supported: boolean;
  installCommand: string;
}

export interface WorkspaceSettings {
  defaultProvider: RunProvider;
  defaultModels: Record<string, string>;
  /// Reasoning effort per agent for new sessions (absent: the agent's own default).
  defaultEfforts: Record<string, string>;
  /// The account last chosen per agent.
  defaultProfiles: Record<string, string>;
  defaultMode: ExecutionMode;
  defaultIsolation: IsolationMode;
  defaultPermission: PermissionPolicy;
  worktreeRoot: string;
  autoArchiveDays: number;
  showCost: boolean;
  agentTools: boolean;
  steerByDefault: boolean;
  autoResumeLimited: boolean;
  lastProject: string;
  recentProjects: string[];
}

export interface WorkspaceOverview {
  runs: WorkspaceRun[];
  running: string[];
  gitAvailable: boolean;
  providers: ProviderInfo[];
  settings: WorkspaceSettings;
}

export type PathVerdict = "ok" | "missing" | "notDirectory" | "unreadable" | "forbidden";

export interface ProjectInfo {
  path: string;
  name: string;
  verdict: PathVerdict;
  verdictMessage: string;
  repoRoot: string | null;
  currentBranch: string | null;
  branches: string[];
  defaultBase: string | null;
  hasCommits: boolean;
  dirtyFiles: number;
  isWorktree: boolean;
}

export interface NewRunConfig {
  title: string;
  task: string;
  provider: RunProvider;
  profileId: string;
  model: string;
  mode: ExecutionMode;
  permission: PermissionPolicy;
  isolation: IsolationMode;
  projectPath: string;
  baseBranch: string;
  branchName: string;
  worktreeRoot: string;
  instructions: string;
  effort: string | null;
}

export type ChangeKind = "added" | "modified" | "deleted" | "renamed" | "copied" | "untracked" | "conflicted" | "typeChanged";
export interface FileChange {
  path: string;
  oldPath: string | null;
  kind: ChangeKind;
  staged: boolean;
  unstaged: boolean;
  added: number | null;
  removed: number | null;
}
export interface GitStatus { branch: string | null; upstream: string | null; ahead: number; behind: number; detached: boolean; files: FileChange[] }
export interface GitSnapshot { status: GitStatus | null; ahead: number | null; behind: number | null; error: string | null; loading: boolean }
export interface TreeRow {
  depth: number;
  isDirectory: boolean;
  name: string;
  path: string;
  added: number;
  removed: number;
  fileCount: number;
  hasNumbers: boolean;
  kind: ChangeKind | null;
}
export interface GitView { snapshot: GitSnapshot | null; tree: TreeRow[] }

export interface Worktree { path: string; head: string; branch: string | null; isMain: boolean; locked: boolean; prunable: boolean }
export interface WorktreeRow {
  repoRoot: string;
  worktree: Worktree;
  runIds: string[];
  changedFiles: number | null;
  ahead: number | null;
  behind: number | null;
  baseBranch: string | null;
}

export type UsageRange = "today" | "week" | "month" | "all";
export interface UsageFilter { range: UsageRange; provider: RunProvider | null; model: string | null; project: string | null }
export interface UsageRow {
  provider: RunProvider;
  model: string;
  sessions: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  reportedCostUsd: number | null;
  sessionsWithoutTokens: number;
}
export interface UsageReport {
  sessions: number;
  completed: number;
  failed: number;
  running: number;
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
  reportedCostUsd: number | null;
  sessionsWithCost: number;
  sessionsWithTokens: number;
  rows: UsageRow[];
  days: { day: string; provider: RunProvider; tokens: number }[];
}

export type QuickAction = "commit" | "commitPush" | "commitPushPr" | "push" | "pushPr" | "createPr" | "pull";
export interface QuickView {
  state: { branch: string | null; hasChanges: boolean; isDefaultBranch: boolean; hasUpstream: boolean; hasRemote: boolean; ahead: number; behind: number; aheadOfBase: number; hasOpenPullRequest: boolean };
  action: QuickAction | null;
  label: string | null;
  reason: string | null;
  hostName: string | null;
  remote: string | null;
  base: string | null;
  pullRequest: string | null;
  canCreateHere: boolean;
}
export interface PullRequestDraft { title: string; body: string; head: string; base: string }

const run = (id: string) => id.replace(/^run:/, "");

export const workspaceApi = {
  overview: () => invoke<WorkspaceOverview>("workspace_overview"),
  saveSettings: (settings: WorkspaceSettings) => invoke<void>("workspace_save_settings", { settings }),
  forgetProject: (path: string) => invoke<void>("workspace_forget_project", { path }),
  timeline: (id: string) => invoke<RunEvent[]>("workspace_timeline", { run: run(id) }),
  queue: (id: string) => invoke<MessageQueue>("workspace_queue", { run: run(id) }),
  inspect: (path: string) => invoke<ProjectInfo>("workspace_inspect", { path }),
  start: (config: NewRunConfig, allowShared: boolean) => invoke<string>("workspace_start", { config, allowShared }),
  adopt: (a: { provider: RunProvider; sessionId: string; profileId: string; directory: string; title: string; history: [EventKind, string][]; fork: boolean }) =>
    invoke<string>("workspace_adopt", a),
  configure: (id: string, c: { mode?: ExecutionMode; permission?: PermissionPolicy; model?: string; effort?: string | null }) =>
    invoke<void>("workspace_configure", {
      run: run(id),
      mode: c.mode ?? null,
      permission: c.permission ?? null,
      model: c.model ?? null,
      effort: c.effort ?? null,
      setEffort: "effort" in c,
    }),
  send: (id: string, text: string) => invoke<void>("workspace_send", { run: run(id), text }),
  steer: (id: string, text: string) => invoke<boolean>("workspace_steer", { run: run(id), text }),
  enqueue: (id: string, text: string) => invoke<void>("workspace_enqueue", { run: run(id), text }),
  queueRemove: (id: string, message: string) => invoke<void>("workspace_queue_remove", { run: run(id), message }),
  queueMove: (id: string, message: string, toIndex: number) => invoke<void>("workspace_queue_move", { run: run(id), message, toIndex }),
  queueEdit: (id: string, message: string, text: string) => invoke<void>("workspace_queue_edit", { run: run(id), message, text }),
  queueSendNow: (id: string) => invoke<void>("workspace_queue_send_now", { run: run(id) }),
  queueSteer: (id: string, message: string) => invoke<void>("workspace_queue_steer", { run: run(id), message }),
  stop: (id: string) => invoke<void>("workspace_stop", { run: run(id) }),
  retry: (id: string) => invoke<void>("workspace_retry", { run: run(id) }),
  setAutoResume: (id: string, on: boolean) => invoke<void>("workspace_set_auto_resume", { run: run(id), on }),
  continueLive: (sessionId: string, message: string | null, endingTerminal: boolean) =>
    invoke<string>("workspace_continue_live", { sessionId, message, endingTerminal }),
  continuePast: (key: string, message: string | null) => invoke<string>("workspace_continue_past", { key, message }),
  rename: (id: string, title: string) => invoke<void>("workspace_rename", { run: run(id), title }),
  archive: (id: string, archived: boolean) => invoke<void>("workspace_archive", { run: run(id), archived }),
  markReviewed: (id: string) => invoke<void>("workspace_mark_reviewed", { run: run(id) }),
  remove: (id: string) => invoke<void>("workspace_delete", { run: run(id) }),
  usage: (filter: UsageFilter) => invoke<UsageReport>("workspace_usage", { filter }),
  git: (id: string, refresh = false) => invoke<GitView>("workspace_git", { run: run(id), refresh }),
  diff: (id: string, file: FileChange) => invoke<string>("workspace_diff", { run: run(id), file }),
  commit: (id: string, message: string, paths: string[]) => invoke<string>("workspace_commit", { run: run(id), message, paths }),
  clone: (url: string, near: string | null) => invoke<string>("workspace_clone", { url, near }),
  quick: (id: string) => invoke<QuickView>("workspace_quick", { run: run(id) }),
  pull: (id: string) => invoke<void>("workspace_pull", { run: run(id) }),
  commitAll: (id: string, subject: string, body: string) => invoke<string>("workspace_commit_all", { run: run(id), subject, body }),
  pullRequestDraft: (id: string, base: string) => invoke<PullRequestDraft>("workspace_pull_request_draft", { run: run(id), base }),
  createPullRequest: (id: string, d: PullRequestDraft & { draft: boolean }) =>
    invoke<{ url: string; created: boolean }>("workspace_create_pull_request", { run: run(id), ...d }),
  push: (id: string) => invoke<string>("workspace_push", { run: run(id) }),
  canRevert: (id: string, before: string) => invoke<boolean>("workspace_can_revert", { run: run(id), before }),
  revert: (id: string, before: string) => invoke<void>("workspace_revert", { run: run(id), before }),
  worktrees: (refresh = false) => invoke<WorktreeRow[]>("workspace_worktrees", { refresh }),
  removeWorktree: (repo: string, path: string, force: boolean) => invoke<void>("workspace_remove_worktree", { repo, path, force }),
};

export const workspaceEvents = {
  onChanged: (cb: () => void): Promise<UnlistenFn> => listen("workspace-changed", () => cb()),
  onTimeline: (cb: (runId: string) => void): Promise<UnlistenFn> => listen<string>("workspace-timeline", (e) => cb(e.payload)),
};

export const statusLabels: Record<RunStatus, string> = {
  preparing: "Voorbereiden",
  running: "Bezig",
  waitingApproval: "Wacht op goedkeuring",
  completed: "Klaar",
  failed: "Mislukt",
  stopped: "Gestopt",
};

export const isActive = (s: RunStatus) => s === "preparing" || s === "running" || s === "waitingApproval";

export const permissionLabels: Record<PermissionPolicy, string> = {
  ask: "Alles vragen",
  acceptEdits: "Bewerkingen toestaan",
  bypass: "Alles toestaan",
};

/// Wat een recht betekent bij deze agent (de teksten van de Mac, met "je computer" in plaats van "je Mac").
export function permissionHelp(policy: PermissionPolicy, provider: RunProvider): string {
  const claude: Record<PermissionPolicy, string> = {
    ask: "Elke bewerking en elk commando vraagt eerst om je goedkeuring, hier of in de balk.",
    acceptEdits: "Bestanden aanpassen mag; commando's en andere tools vragen eerst om goedkeuring.",
    bypass: "Geen enkele vraag: de agent voert alles uit, ook commando's. Een worktree beschermt je code, niet je computer.",
  };
  const codex: Record<PermissionPolicy, string> = {
    ask: "Elk commando en elke bewerking buiten de sandbox vraagt eerst om je goedkeuring, hier of in de balk.",
    acceptEdits: "Codex werkt in zijn sandbox: schrijven alleen in de werkmap, geen netwerk.",
    bypass: "Geen sandbox: Codex mag alles op je computer, ook buiten de werkmap.",
  };
  const other: Record<PermissionPolicy, string> = {
    ask: "De agent vraagt Nook om toestemming voor bewerkingen en commando's; lezen mag altijd.",
    acceptEdits: "Bewerkingen worden meteen toegestaan; commando's vragen eerst om je goedkeuring.",
    bypass: "Alles wordt meteen toegestaan, ook commando's. Een worktree beschermt je code, niet je computer.",
  };
  return (provider === "claude" ? claude : provider === "codex" ? codex : other)[policy];
}

export const modeHelp: Record<ExecutionMode, string> = {
  agent: "De agent mag werken in de map, binnen de rechten hieronder.",
  plan: "Alleen lezen en een plan maken; er wordt niets aangepast.",
};

/// Redeneerniveaus (EffortLevels op de Mac): Codex via `model_reasoning_effort`, Claude Code via `--effort`; low,
/// medium and high are the levels every model accepts.
export function effortLevels(provider: RunProvider): string[] {
  return provider === "codex" || provider === "claude" ? ["low", "medium", "high"] : [];
}

export const effortLabels: Record<string, string> = {
  "": "Standaard",
  minimal: "Minimaal",
  low: "Laag",
  medium: "Gemiddeld",
  high: "Hoog",
  xhigh: "Extra hoog",
};

export function projectName(path: string): string {
  const name = path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "";
  return name || "geen map";
}

// MARK: Gereedschap: terminals, browser, scripts en dev-servers

export interface TerminalInfo {
  id: string;
  shortId: string;
  title: string;
  origin: string;
  command: string | null;
  owner: { agent: string; key: string } | null;
  running: boolean;
  exitCode: number | null;
  created: string;
}

export interface ProjectScript { id: string; name: string; command: string; runOnWorktreeCreate: boolean; previewUrl: string | null; autoOpenPreview: boolean }
export interface DevServer { pid: number; command: string; port: number; url: string }
export interface BrowserState { open: boolean; url: string; title: string; loading: boolean; openedBy: string | null; lastError: string | null; unavailable?: string }

export const toolsApi = {
  terminals: () => invoke<TerminalInfo[]>("terminal_list"),
  openTerminal: (directory: string | null, command: string | null = null, title: string | null = null) =>
    invoke<TerminalInfo>("terminal_open", { directory, command, title }),
  write: (id: string, data: string) => invoke<void>("terminal_write", { id, data }),
  resize: (id: string, cols: number, rows: number) => invoke<void>("terminal_resize", { id, cols, rows }),
  replay: (id: string) => invoke<string>("terminal_replay", { id }),
  interrupt: (id: string) => invoke<void>("terminal_interrupt", { id }),
  closeTerminal: (id: string) => invoke<void>("terminal_close", { id }),
  folderTools: (folder: string) => invoke<{ scripts: ProjectScript[]; servers: DevServer[] }>("workspace_folder_tools", { folder }),
  linkBridge: (provider: RunProvider) => invoke<TerminalInfo>("workspace_link_bridge", { provider }),
  browser: () => invoke<BrowserState>("browser_state"),
  go: (input: string) => invoke<void>("browser_go", { input }),
  step: (action: "back" | "forward" | "reload") => invoke<void>("browser_step", { action }),
  read: () => invoke<{ title: string; url: string; text: string }>("browser_read"),
  closeBrowser: () => invoke<void>("browser_close"),
};

export const toolEvents = {
  onOutput: (cb: (c: { id: string; data: string }) => void): Promise<UnlistenFn> =>
    listen<{ id: string; data: string }>("terminal-output", (e) => cb(e.payload)),
  onTerminals: (cb: () => void): Promise<UnlistenFn> => listen("terminals-changed", () => cb()),
  onBrowser: (cb: () => void): Promise<UnlistenFn> => listen("browser-changed", () => cb()),
};
