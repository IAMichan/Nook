// De werkruimte: dezelfde vormen als de Rust-structs in nook_core::workspace, en de aanroepen naar de Rust-kant.
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { tr } from "../i18n.svelte";

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
  /** The lines the session's changes add and remove, for "+120 −8" in the Agents list; null until git was read. */
  linesAdded?: number | null;
  linesRemoved?: number | null;
  checkpoints: {
    ref: string;
    date: string;
    conversation?: { session: string | null; provider: RunProvider | null; turns: number; head: string | null; exact: boolean };
  }[];
  limitedAt: string | null;
  limitResetAt: string | null;
  autoResume: boolean;
  effort: string | null;
  /** The session's active goal (`/goal`, AG-67). */
  goal?: string | null;
  /** True while the agent is compacting/summarizing the conversation (AG-65). */
  compacting?: boolean;
  /** The agent's own task list of the current work (TodoWrite, a Codex plan, an ACP plan). */
  tasks?: { text: string; status: "pending" | "active" | "done" | "cancelled" }[] | null;
}

export type ContextLevel = "normal" | "warning" | "critical";
export type ContextPartKind = "used" | "buffer" | "free";

export interface ContextPart {
  id: string;
  tokens: number;
  share: number;
  kind: ContextPartKind;
}

export interface ContextUsage {
  usedTokens: number;
  window: number;
  fraction: number;
  pressure: number;
  level: ContextLevel;
  autoCompactAt: number | null;
  headroomTokens: number;
  compacting: boolean;
  detailed: boolean;
  parts: ContextPart[];
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
  /** This entry was rolled back: the agent no longer remembers it (AG-62). */
  rolledBack?: boolean;
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
  /** Forks at an earlier turn too, not only at the end. */
  canForkFromTurn: boolean;
  /** Rolls back its own conversation when restoring or editing from an earlier message (AG-62). */
  canRollbackConversation: boolean;
  /** Model, mode and effort picked during a turn reach it at once; otherwise from the next message. */
  liveSettings: boolean;
  /** A denial's reason goes in the answer; otherwise as a message right after it. */
  denyReasonInResponse: boolean;
  speedTiers: boolean;
  ultracode: boolean;
  /** A steered message comes back once the agent reads it ("waiting to be read" until then). */
  echoesSteers: boolean;
}

export interface ProviderInfo {
  provider: RunProvider;
  name: string;
  capabilities: ProviderCapabilities;
  executable: string | null;
  supported: boolean;
  installCommand: string;
}

/// What was chosen for one agent in one folder.
export interface FolderAgentChoice {
  profileId: string;
  model: string;
  /// Null: the agent's own default, also when another folder has a level.
  effort: string | null;
}

/// What the new-session composer last chose in one folder.
export interface FolderChoices {
  provider: RunProvider;
  mode: ExecutionMode;
  permission: PermissionPolicy;
  isolation: IsolationMode;
  agents: Record<string, FolderAgentChoice>;
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
  continueAfterRelaunch?: boolean;
  lastProject: string;
  favoriteProjects?: string[];
  recentProjects: string[];
  /// The composer's last choices per folder, on top of the defaults above.
  folderChoices?: Record<string, FolderChoices>;
  /// What every branch Nook names starts with ("nook"); Settings › Sessions › Worktrees.
  branchPrefix?: string;
  /// Keep what Nook and each agent send each other (Settings › System › Diagnostics).
  keepTraffic?: boolean;
  /// Instructions every agent gets at launch, in every project that does not set its own.
  agentInstructions?: string;
  /// The editor a session's folder opens in ("code", "cursor", …); empty: the file manager.
  editor?: string;
  /// At most this many sessions may work at once (`ws.maxWorkingSessions` on macOS, AG-75); 0 = no limit.
  maxWorkingSessions?: number;
  /** Look for new models online (`ws.onlineModelList` on the Mac); off, only the list that came with the app. */
  onlineModelList?: boolean;
  /// How much of the agent's work a timeline shows (`ws.timelineDetail`; `timeline-detail.ts`); absent: everything.
  timelineDetail?: string;
  /// What a screen reader hears from the open session (`ws.screenReaderAnnouncements`; `announcements.ts`).
  screenReaderAnnouncements?: string;
  /// Commit and pull request message style (`ws.commitStyle`, AG-122).
  commitStyle?: CommitStyle;
  /// Custom instructions when `commitStyle === "custom"`.
  commitInstructions?: string;
  /// Coding agents never add AI co-author trailers or "Generated with …" lines.
  noAgentCredits?: boolean;
  /// Strip AI agent credits from merge commits and commit bodies written by Nook.
  stripAgentCredits?: boolean;
  /// Suggest a follow-up prompt in the empty session composer (`ws.suggestNextPrompt`, SV-65).
  suggestNextPrompt?: boolean;
  /// Per-kind text generator choice (`"titles"`, `"gitText"`, `"nextPrompt"` -> `"agent"` or `"api:<provider>:<model>"`).
  textGenerators?: Record<string, string>;
}

export type CommitStyle = "standard" | "conventional" | "repository" | "custom";

/// Answer to a quick side question (`/btw`, `/side`, AG-61) asked while a session keeps running.
export interface SideChatReply {
  question: string;
  answer: string;
  model: string;
  createdAt: string;
}

/// What one project sets for itself (Settings › Projects); a field left out follows the setting for all projects.
export interface ProjectOverride {
  name?: string | null;
  provider?: RunProvider | null;
  mode?: ExecutionMode | null;
  permission?: PermissionPolicy | null;
  isolation?: IsolationMode | null;
  branchPrefix?: string | null;
  titleInstructions?: string | null;
  agentInstructions?: string | null;
  archived?: boolean;
}

/// The values a new session in a project starts with, and which of them the project sets itself (`own`).
export interface ProjectDefaults {
  provider: RunProvider;
  mode: ExecutionMode;
  permission: PermissionPolicy;
  isolation: IsolationMode;
  branchPrefix: string;
  titleInstructions: string;
  agentInstructions: string;
  own: string[];
}

export interface ProjectSettingsView {
  path: string;
  override: ProjectOverride;
  defaults: ProjectDefaults;
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

export type QuickAction = "commit" | "commitPush" | "commitPushPr" | "push" | "pushPr" | "createPr" | "pull" | "branchCommitPushPr" | "branchPushPr";
export interface QuickView {
  state: { branch: string | null; hasChanges: boolean; isDefaultBranch: boolean; hasUpstream: boolean; hasRemote: boolean; ahead: number; behind: number; aheadOfBase: number; hasOpenPullRequest: boolean; pullRequestLanded: boolean };
  action: QuickAction | null;
  label: string | null;
  reason: string | null;
  destination: string | null;
  alternatives: QuickAction[];
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
  /// The editors on this computer; and opening a folder where Settings says (the session view's "Open in").
  editors: () => invoke<{ id: string; name: string }[]>("workspace_editors"),
  openIn: (folder: string) => invoke<void>("workspace_open_in", { folder }),
  /// What a project sets for itself and the values a new session there starts with.
  projectSettings: (path: string) => invoke<ProjectSettingsView>("workspace_project_settings", { path }),
  setProjectSettings: (path: string, value: ProjectOverride) => invoke<ProjectSettingsView>("workspace_set_project_settings", { path, value }),
  toggleFavoriteProject: (path: string) => invoke<void>("workspace_toggle_favorite_project", { path }),
  timeline: (id: string) => invoke<RunEvent[]>("workspace_timeline", { run: run(id) }),
  queue: (id: string) => invoke<MessageQueue>("workspace_queue", { run: run(id) }),
  inspect: (path: string) => invoke<ProjectInfo>("workspace_inspect", { path }),
  start: (config: NewRunConfig, allowShared: boolean) => invoke<string>("workspace_start", { config, allowShared }),
  /** A new session that starts from this one; `keep`: the timeline entries that stay (a fork from an earlier point). */
  fork: (id: string, keep?: number) => invoke<string>("workspace_fork", { run: run(id), keep: keep ?? null }),
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
  continueInterrupted: (skip: string[]) => invoke<number>("workspace_continue_interrupted", { skip }),
  dismissQuestion: (id: string) => invoke<void>("workspace_dismiss_question", { id }),
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
  /** Stages or discards one hunk of a file's diff (`HunkPatch`), counted from the first. */
  applyHunk: (id: string, file: FileChange, index: number, action: "stage" | "discard") =>
    invoke<void>("workspace_apply_hunk", { run: run(id), file, index, action }),
  commit: (id: string, message: string, paths: string[]) => invoke<string>("workspace_commit", { run: run(id), message, paths }),
  clone: (url: string, near: string | null) => invoke<string>("workspace_clone", { url, near }),
  quick: (id: string) => invoke<QuickView>("workspace_quick", { run: run(id) }),
  pull: (id: string) => invoke<void>("workspace_pull", { run: run(id) }),
  startBranch: (id: string, topic: string) => invoke<{ branch: string; cut: string | null }>("workspace_start_branch", { run: run(id), topic }),
  moveOntoBase: (id: string, cut: string) => invoke<boolean>("workspace_move_onto_base", { run: run(id), cut }),
  commitAll: (id: string, subject: string, body: string) => invoke<string>("workspace_commit_all", { run: run(id), subject, body }),
  pullRequestDraft: (id: string, base: string) => invoke<PullRequestDraft>("workspace_pull_request_draft", { run: run(id), base }),
  createPullRequest: (id: string, d: PullRequestDraft & { draft: boolean }) =>
    invoke<{ url: string; created: boolean }>("workspace_create_pull_request", { run: run(id), ...d }),
  push: (id: string) => invoke<string>("workspace_push", { run: run(id) }),
  canRevert: (id: string, before: string, conversationOnly = false) =>
    invoke<boolean>("workspace_can_revert", { run: run(id), before, conversationOnly }),
  revert: (id: string, before: string, keepFiles = false) =>
    invoke<void>("workspace_revert", { run: run(id), before, keepFiles }),
  saveMarkdown: (path: string, text: string) => invoke<void>("workspace_save_markdown", { path, text }),
  /** A project's own icon as a data: address, or null (`ProjectFavicon`). */
  favicon: (path: string) => invoke<string | null>("workspace_favicon", { path }),
  /** Sessions whose title or conversation holds the words, archived ones too. */
  search: (query: string) => invoke<{ runId: string; snippet: string; archived: boolean }[]>("workspace_search", { query }),
  /** Files in a project folder matching `query`, for `@` mentions and the File side-panel tab. */
  files: (root: string, query = "") => invoke<string[]>("workspace_files", { root, query }),
  /** The `/` commands the session's agent announced itself (ACP). */
  agentCommands: (id: string) => invoke<{ name: string; detail: string; takesInput: boolean }[]>("workspace_agent_commands", { run: run(id) }),
  /** The CPU and memory of a working session's agent and what it started; null without a process or on a first read. */
  resources: (id: string) => invoke<{ cpuPercent: number; memoryBytes: number; processes: number } | null>("workspace_resources", { run: run(id) }),
  /** `/clear`: a new conversation with the agent; false while it works. */
  clear: (id: string) => invoke<boolean>("workspace_clear", { run: run(id) }),
  /** Sets or clears a session's active goal (`/goal`, AG-67). */
  setGoal: (id: string, goal: string | null) => invoke<string | null>("workspace_set_goal", { run: run(id), goal }),
  /** Context window breakdown and compaction pressure for a session (AG-65 & AG-66). */
  contextUsage: (id: string) => invoke<ContextUsage | null>("workspace_context_usage", { run: run(id) }),
  /** Quick side question (`/btw`, `/side`, AG-61) answered with recent timeline context while the main agent keeps running. */
  sideChat: (id: string, question: string) => invoke<SideChatReply>("workspace_side_chat", { run: run(id), question }),
  /** "Turn into project": a session's folder without a project becomes a favorite project. */
  keepScratch: (path: string) => invoke<void>("workspace_keep_scratch", { path }),
  /** "Make it a git repository": `git init` in a session's folder. */
  initGit: (path: string) => invoke<void>("workspace_init_git", { path }),
  worktrees: (refresh = false) => invoke<WorktreeRow[]>("workspace_worktrees", { refresh }),
  removeWorktree: (repo: string, path: string, force: boolean) => invoke<void>("workspace_remove_worktree", { repo, path, force }),
};

export const workspaceEvents = {
  onChanged: (cb: () => void): Promise<UnlistenFn> => listen("workspace-changed", () => cb()),
  onTimeline: (cb: (runId: string) => void): Promise<UnlistenFn> => listen<string>("workspace-timeline", (e) => cb(e.payload)),
};

// The name tables read through getters, so each read is in the current interface language.
export const statusLabels: Record<RunStatus, string> = {
  get preparing() { return tr("Voorbereiden", "Preparing"); },
  get running() { return tr("Bezig", "Running"); },
  get waitingApproval() { return tr("Wacht op goedkeuring", "Waiting for approval"); },
  get completed() { return tr("Klaar", "Done"); },
  get failed() { return tr("Mislukt", "Failed"); },
  get stopped() { return tr("Gestopt", "Stopped"); },
};

export const isActive = (s: RunStatus) => s === "preparing" || s === "running" || s === "waitingApproval";

export const permissionLabels: Record<PermissionPolicy, string> = {
  get ask() { return tr("Alles vragen", "Ask for everything"); },
  get acceptEdits() { return tr("Bewerkingen toestaan", "Allow edits"); },
  get bypass() { return tr("Alles toestaan", "Allow everything"); },
};

/// Wat een recht betekent bij deze agent (de teksten van de Mac, met "je computer" in plaats van "je Mac").
export function permissionHelp(policy: PermissionPolicy, provider: RunProvider): string {
  if (provider === "claude") {
    switch (policy) {
      case "ask": return tr("Elke bewerking en elk commando vraagt eerst om je goedkeuring, hier of in de balk.", "Every edit and every command asks for your approval first, here or in the bar.");
      case "acceptEdits": return tr("Bestanden aanpassen mag; commando's en andere tools vragen eerst om goedkeuring.", "Editing files is allowed; commands and other tools ask for approval first.");
      case "bypass": return tr("Geen enkele vraag: de agent voert alles uit, ook commando's. Een worktree beschermt je code, niet je computer.", "No questions at all: the agent runs everything, commands included. A worktree protects your code, not your computer.");
    }
  }
  if (provider === "codex") {
    switch (policy) {
      case "ask": return tr("Elk commando en elke bewerking buiten de sandbox vraagt eerst om je goedkeuring, hier of in de balk.", "Every command and every edit outside the sandbox asks for your approval first, here or in the bar.");
      case "acceptEdits": return tr("Codex werkt in zijn sandbox: schrijven alleen in de werkmap, geen netwerk.", "Codex works in its sandbox: writing only in the working folder, no network.");
      case "bypass": return tr("Geen sandbox: Codex mag alles op je computer, ook buiten de werkmap.", "No sandbox: Codex may do anything on your computer, also outside the working folder.");
    }
  }
  switch (policy) {
    case "ask": return tr("De agent vraagt Nook om toestemming voor bewerkingen en commando's; lezen mag altijd.", "The agent asks Nook for permission for edits and commands; reading is always allowed.");
    case "acceptEdits": return tr("Bewerkingen worden meteen toegestaan; commando's vragen eerst om je goedkeuring.", "Edits are allowed right away; commands ask for your approval first.");
    case "bypass": return tr("Alles wordt meteen toegestaan, ook commando's. Een worktree beschermt je code, niet je computer.", "Everything is allowed right away, commands included. A worktree protects your code, not your computer.");
  }
}

export const modeHelp: Record<ExecutionMode, string> = {
  get agent() { return tr("De agent mag werken in de map, binnen de rechten hieronder.", "The agent may work in the folder, within the permissions below."); },
  get plan() { return tr("Alleen lezen en een plan maken; er wordt niets aangepast.", "Only read and make a plan; nothing is changed."); },
};

/// Redeneerniveaus (EffortLevels op de Mac): Codex via `model_reasoning_effort`, Claude Code via `--effort`; low,
/// medium and high are the levels every model accepts.
export function effortLevels(provider: RunProvider): string[] {
  return provider === "codex" || provider === "claude" ? ["low", "medium", "high"] : [];
}

export const effortLabels: Record<string, string> = {
  get ""() { return tr("Standaard", "Default"); },
  get minimal() { return tr("Minimaal", "Minimal"); },
  get low() { return tr("Laag", "Low"); },
  get medium() { return tr("Gemiddeld", "Medium"); },
  get high() { return tr("Hoog", "High"); },
  get xhigh() { return tr("Extra hoog", "Extra high"); },
};

/// A folder Nook made for a session without a project (`ScratchProjects`): directly in ~/.nook/scratch.
export function isScratch(path: string | null | undefined): boolean {
  return !!path && /[\\/]\.nook[\\/]scratch[\\/][^\\/]+[\\/]?$/.test(path);
}

export function projectName(path: string): string {
  const name = path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? "";
  return name || tr("geen map", "no folder");
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
export interface DevServer { pid: number; command: string; port: number; url: string; /** Started by Nook: only such a server can be stopped from here (AG-134). */ startedByNook?: boolean }
export interface BrowserState { open: boolean; url: string; title: string; loading: boolean; openedBy: string | null; lastError: string | null; unavailable?: string }

export const toolsApi = {
  terminals: () => invoke<TerminalInfo[]>("terminal_list"),
  openTerminal: (
    directory: string | null,
    command: string | null = null,
    title: string | null = null,
    size?: { cols: number; rows: number } | null,
  ) => invoke<TerminalInfo>("terminal_open", { directory, command, title, cols: size?.cols ?? null, rows: size?.rows ?? null }),
  write: (id: string, data: string) => invoke<void>("terminal_write", { id, data }),
  resize: (id: string, cols: number, rows: number) => invoke<void>("terminal_resize", { id, cols, rows }),
  replay: (id: string) => invoke<string>("terminal_replay", { id }),
  interrupt: (id: string) => invoke<void>("terminal_interrupt", { id }),
  closeTerminal: (id: string) => invoke<void>("terminal_close", { id }),
  devServers: (folder: string) => invoke<DevServer[]>("workspace_dev_servers", { folder }),
  /** True when it was stopped; false for a server Nook did not start. */
  stopDevServer: (folder: string, pid: number, port: number) => invoke<boolean>("workspace_stop_dev_server", { folder, pid, port }),
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
