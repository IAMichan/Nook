<script lang="ts">
  import { loadOptions, optionId, optionLabel, snoozeMenu } from "../../lib/snooze-options";
  import { loadAgentsView, onAgentsView, saveAgentsView, type AgentsView } from "../../lib/agents-view";
  // De tab Agents (`AgentsTab` en `AgentInboxList` op de Mac): links elke sessie, van welke agent ook, hier of in een
  // terminal gestart; rechts de gekozen sessie, of na de knop "Nieuwe sessie" de plek om er een te starten. Wat op jou
  // wacht staat bovenaan, daarna wat werkt, dan de rest; eerdere sessies wachten ingeklapt onderaan.
  import { agentNames, type AgentSession, type PastSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";
  import { isActive, isScratch, projectName, workspaceApi, type WorkspaceRun } from "../../lib/workspace/api";
  import { composerInbox } from "../../lib/workspace/composer-inbox.svelte";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Browser from "../workspace/Browser.svelte";
  import Terminals from "../workspace/Terminals.svelte";
  import GrantedRulesSheet from "./GrantedRulesSheet.svelte";
  import AddProjectPalette from "./AddProjectPalette.svelte";
  import UsageModal from "./UsageModal.svelte";
  import EmptyState from "./EmptyState.svelte";
  import Worktrees from "../workspace/Worktrees.svelte";
  import LiveDetail from "./LiveDetail.svelte";
  import PastDetail from "./PastDetail.svelte";
  import Actions from "./actions/Actions.svelte";
  import PullRequests from "./pulls/PullRequests.svelte";
  import PullRequestPill from "./PullRequestPill.svelte";
  import NewSession from "./run/NewSession.svelte";
  import RunPanel from "./run/RunPanel.svelte";
  import { sidePanel } from "./run/side-panel.svelte";
  import { prSync } from "../../lib/workspace/pull-requests.svelte";
  import type { PullRequestLink } from "../../lib/workspace/pull-requests";
  import { ago, folderName } from "./time";
  import { openNewSessionIn } from "./new-session.svelte";
  import { multiProjectLabel } from "../../lib/workspace/project-sources";
  import Ico from "../../components/ui/Ico.svelte";
  import Dropdown from "../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../components/ui/DropdownRow.svelte";
  import ProjectIconView from "../../components/ui/ProjectIconView.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { openUrl, revealItemInDir } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import * as inbox from "../../lib/agent-inbox";
  import { untrack } from "svelte";
  import { onCommands } from "../../lib/commands";
  import {
    autoSettle,
    loadRules as loadAutoSettleRules,
    loadSettleActions,
    loadSettled as loadAutoSettled,
    planSettleActions,
    saveSettled as saveAutoSettled,
  } from "../../lib/auto-settle";
  import { toolsApi } from "../../lib/workspace/api";
  import { describeChange, UNDO_WINDOW_MS, UndoLog, type UndoEntry } from "../../lib/undo-log";
  import { keys as keyRules } from "../../lib/keybindings.svelte";
  import { chordLabel, chordsFor } from "../../lib/keybindings";
  import { emptyState, needsYou, type Attention, type InboxEntry, type InboxState } from "../../lib/agent-inbox";

  let { compact = false }: { compact?: boolean } = $props();
  let query = $state("");
  let showFinished = $state(false);
  // What you decided about the list (pins, settled, snoozed, folded projects) is remembered.
  const STATE_KEY = "nook.agents.inbox";
  // How the list is shown (the Mac's `InboxViewMenu`), shared with Settings › General › Session list (`agents-view`).
  type View = AgentsView;
  const loadView = loadAgentsView;
  let view = $state<View>(loadView());
  function loadState(): InboxState {
    try { return { ...emptyState(), ...JSON.parse(localStorage.getItem(STATE_KEY) ?? "{}"), groupByProject: view.projectFolders }; } catch { return { ...emptyState(), groupByProject: view.projectFolders }; }
  }
  let inboxState = $state<InboxState>(loadState());
  // Once after a launch: sessions that quitting cut off go on by themselves when Settings asks for it (`continueInterrupted`);
  // the ones you settled or snoozed stay as they are.
  let continuedAfterLaunch = false;
  $effect(() => {
    if (continuedAfterLaunch || !workspace.overview) return;
    continuedAfterLaunch = true;
    const now = Date.now();
    const skip = [...inboxState.settled, ...Object.entries(inboxState.snoozed).filter(([, until]) => until > now).map(([id]) => id)].map((id) => id.replace(/^run:/, ""));
    workspaceApi.continueInterrupted(skip).catch(() => {});
  });
  function setView(next: View) {
    view = next;
    saveAgentsView(next);
    update({ ...inboxState, groupByProject: next.projectFolders });
  }
  // A switch in Settings changes the same view.
  $effect(() => onAgentsView((next) => {
    view = next;
    inboxState = { ...inboxState, groupByProject: next.projectFolders };
  }));
  let settledLimit = $state(inbox.settledPage);
  let menuFor = $state<string | null>(null);
  let permissionsSheet = $state<{ project: string | null; tab?: "rules" | "audit" } | null>(null);

  // Custom snooze sheet (`CustomSnoozeSheet` on the Mac, AG-112): pick an exact date & time or a custom duration.
  type SnoozeUnit = "minutes" | "hours" | "days";
  let customSnoozeFor = $state<string | null>(null);
  let customSnoozeMode = $state<"datetime" | "duration">("duration");
  let customSnoozeAt = $state("");
  let customSnoozeAmount = $state(30);
  let customSnoozeUnit = $state<SnoozeUnit>("minutes");

  /// "2026-11-20T09:00" in local time, for the custom snooze field.
  function localMoment(ms: number): string {
    const d = new Date(ms);
    const p = (n: number) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  function openCustomSnooze(id: string) {
    menuFor = null;
    customSnoozeFor = id;
    customSnoozeAt = localMoment(Date.now() + 60 * 60 * 1000);
    customSnoozeAmount = 30;
    customSnoozeUnit = "minutes";
  }

  const customSnoozeTarget = $derived.by(() => {
    if (customSnoozeMode === "datetime") {
      const parsed = Date.parse(customSnoozeAt);
      return Number.isFinite(parsed) ? parsed : 0;
    }
    const n = Math.max(1, Math.min(999, Math.floor(Number(customSnoozeAmount) || 0)));
    const mult = customSnoozeUnit === "days" ? 86_400_000 : customSnoozeUnit === "hours" ? 3_600_000 : 60_000;
    return now + n * mult;
  });

  function applyCustomSnooze() {
    if (!customSnoozeFor || customSnoozeTarget <= now) return;
    update(inbox.snooze(inboxState, customSnoozeFor, customSnoozeTarget));
    customSnoozeFor = null;
  }

  function formatSnoozePreview(ms: number): string {
    if (ms <= now) return "";
    const d = new Date(ms);
    const today = new Date(now);
    const sameDay = d.getFullYear() === today.getFullYear() && d.getMonth() === today.getMonth() && d.getDate() === today.getDate();
    return sameDay
      ? d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" })
      : d.toLocaleString(locale(), { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
  }

  // Runs Settle actions (`SettleActionRules`, AG-111) when one or more sessions move to Done.
  async function runSettleActionsFor(newlySettledIds: string[], nextState: InboxState) {
    if (!newlySettledIds.length) return;
    const actions = loadSettleActions();
    if (!actions.stopDevServersOnSettle && !actions.closeIdleTerminalsOnSettle && !actions.settleCommand.trim()) return;
    const settledSet = new Set(nextState.settled);
    const otherUnsettledFolders = all.filter((i) => !settledSet.has(i.id) && i.path).map((i) => i.path);
    const handledFolders = new Set<string>();
    for (const id of newlySettledIds) {
      const item = byId.get(id);
      if (!item?.path) continue;
      const plan = planSettleActions(item.path, otherUnsettledFolders, actions);
      if (!plan || handledFolders.has(plan.folder)) continue;
      handledFolders.add(plan.folder);
      if (plan.stopDevServers || plan.closeIdleTerminals) {
        toolsApi
          .terminals()
          .then((terms) => {
            for (const t of terms) {
              const tFolder = (t.origin ?? "").trim().replace(/[\\/]+$/, "");
              if (tFolder !== plan.folder) continue;
              if (plan.stopDevServers && t.running) {
                toolsApi.closeTerminal(t.id).catch(() => {});
              } else if (plan.closeIdleTerminals && !t.running) {
                toolsApi.closeTerminal(t.id).catch(() => {});
              }
            }
          })
          .catch(() => {});
      }
      if (plan.command) {
        toolsApi.openTerminal(plan.folder, plan.command, "Settle").catch(() => {});
      }
    }
  }

  // The last list actions (settle, pin, snooze…), for `session.undo` (the Mac's `store.undo()`).
  const undoStack: InboxState[] = [];
  // The one-line notice for the last of them (`UndoLog`): "3 sessions settled · Ctrl+Z", for five seconds.
  const undoLog = new UndoLog();
  let undoNotice = $state<UndoEntry | null>(null);
  let undoTimer: ReturnType<typeof setTimeout> | null = null;
  function showUndo() {
    undoNotice = undoLog.current(Date.now());
    if (undoTimer) clearTimeout(undoTimer);
    undoTimer = undoNotice ? setTimeout(showUndo, Math.max(50, undoNotice.createdAt + UNDO_WINDOW_MS - Date.now())) : null;
  }
  function undoLast() {
    const previous = undoStack.pop();
    if (!previous) return false;
    undoLog.undo(Date.now());
    update(previous, false);
    showUndo();
  }
  const undoKey = $derived(chordsFor("session.undo", keyRules.rules)[0]);
  function undoText(e: UndoEntry): string {
    const n = e.ids.length;
    switch (e.kind) {
      case "settled": return n === 1 ? tr("Sessie afgehandeld", "Session settled") : tr("{n} sessies afgehandeld", "{n} sessions settled", { n });
      case "unsettled": return n === 1 ? tr("Sessie weer open", "Session reopened") : tr("{n} sessies weer open", "{n} sessions reopened", { n });
      case "snoozed": return n === 1 ? tr("Sessie gesnoozed", "Session snoozed") : tr("{n} sessies gesnoozed", "{n} sessions snoozed", { n });
      case "pinned": return n === 1 ? tr("Sessie vastgezet", "Session pinned") : tr("{n} sessies vastgezet", "{n} sessions pinned", { n });
      case "unpinned": return n === 1 ? tr("Sessie losgemaakt", "Session unpinned") : tr("{n} sessies losgemaakt", "{n} sessions unpinned", { n });
    }
  }
  function update(next: InboxState, record = true) {
    const prevSettled = new Set(inboxState.settled);
    const newlySettled = next.settled.filter((id) => !prevSettled.has(id));
    if (record && next !== inboxState) {
      undoStack.push(inboxState);
      const change = describeChange(inboxState, next, Date.now());
      if (change) {
        undoLog.record(change.kind, change.ids, Date.now());
        queueMicrotask(showUndo);
      }
    }
    if (undoStack.length > 20) undoStack.shift();
    inboxState = next;
    menuFor = null;
    try { localStorage.setItem(STATE_KEY, JSON.stringify(next)); } catch { /* No storage: the choice lasts until the window closes. */ }
    if (newlySettled.length) {
      runSettleActionsFor(newlySettled, next).catch(() => {});
    }
  }

  // Listen for `"nook-agents-snooze"` dispatched by `Timeline.svelte`'s "Snooze until reset" button (AG-80).
  $effect(() => {
    const onSnooze = (e: Event) => {
      const detail = (e as CustomEvent<{ id: string; until: number }>).detail;
      if (!detail?.id || !(detail.until > Date.now())) return;
      update(inbox.snooze(inboxState, detail.id, detail.until));
    };
    window.addEventListener("nook-agents-snooze", onSnooze);
    return () => window.removeEventListener("nook-agents-snooze", onSnooze);
  });
  let now = $state(Date.now());
  // In the main window the session list is the sidebar's list, as on the Mac: the column moves into the sidebar slot.
  let docked = $state(false);
  function dock(node: HTMLElement) {
    if (compact) return;
    const slot = document.getElementById("sidebar-slot");
    // A narrow window folds the sidebar to icons: the list then stays in the page.
    if (!slot || slot.offsetWidth < 180) return;
    slot.appendChild(node);
    docked = true;
  }

  $effect(() => {
    agents.start();
    workspace.start();
    prSync.start();
    agents.loadHistory();
    const timer = setInterval(() => {
      agents.loadHistory();
      now = Date.now();
    }, 30_000);
    return () => clearInterval(timer);
  });

  // Periodically sync branch PR status for visible workspace sessions that have a branch (AG-104).
  $effect(() => {
    const runs = workspace.runs.filter((r) => !r.archived && r.branch && r.workingDirectory).slice(0, 12);
    for (const r of runs) {
      prSync.refresh({ run: r.id, directory: r.workingDirectory, branch: r.branch });
    }
  });

  function openPrFromRow(sessionId: string, link: PullRequestLink) {
    if (sessionId.startsWith("run:") && link.host.kind === "github") {
      agents.select(sessionId);
      sidePanel.openTool(sessionId.slice(4), "pullRequest");
    } else if (link.url) {
      openUrl(link.url).catch(() => {});
    }
  }

  type Status = "waiting" | "input" | "failed" | "limited" | "working" | "idle" | "finished";
  interface Item {
    id: string;
    folder: string;
    title: string;
    branch: string | null;
    agent: string;
    status: Status;
    compacting: boolean;
    started: string | null;
    path: string;
    unseen: boolean;
    /** The lines its changes add and remove ("+120 −8"); 0 when it changed nothing or nothing was counted. */
    added: number;
    removed: number;
    /** Started without a project, in a folder of its own (`ScratchProjects`). */
    scratch: boolean;
    /** The project's folder, for its own icon. */
    root: string;
    /** Other repository roots edited during this session (`SessionProjects`, #1549). */
    otherProjects: string[];
  }

  // Een proces dat Nook alleen ziet, staat er als zijn gesprek te lezen is; koppelen gaat via Instellingen › Agents.
  const kindOf: Record<string, string> = { "Claude Code": "claude", Codex: "codex", "Gemini CLI": "gemini", Antigravity: "antigravity" };
  const live = $derived(
    agents.sessions.filter((s) => s.status !== "detected" || (agents.history?.sessions ?? []).some((p) => p.agent === kindOf[s.name] && p.cwd === s.cwd)),
  );
  // Sessies die Nook zelf draait: bezig, wachtend, of de afgelopen dag klaar; nieuwste eerst.
  const runs = $derived(
    workspace.runs
      .filter((r) => !r.archived && (isActive(r.status) || now - Date.parse(r.updatedAt) < 24 * 3600 * 1000))
      .sort((a, b) => Number(isActive(b.status)) - Number(isActive(a.status)) || b.updatedAt.localeCompare(a.updatedAt))
      .slice(0, 12),
  );
  const runConversations = $derived(new Set(workspace.runs.map((r) => r.providerSessionId).filter(Boolean)));
  const liveConversations = $derived(new Set(live.map((s) => s.sessionId).filter(Boolean)));
  const past = $derived(
    (agents.history?.sessions ?? []).filter((p) => !liveConversations.has(p.sessionId) && !runConversations.has(p.sessionId)).slice(0, 60),
  );

  function unseen(id: string, finished: string | null): boolean {
    if (!finished || id === agents.selectedId) return false;
    const seen = agents.overview?.marks.visits[id];
    return !seen || seen < finished;
  }

  /// A project by the name you gave it in Settings › Projects, else its folder's (`projectDisplayName`).
  function projectLabel(path: string): string {
    const overrides = (workspace.settings as unknown as { projectOverrides?: Record<string, { name?: string | null }> } | null)?.projectOverrides ?? {};
    return overrides[path.replace(/[\\/]+$/, "")]?.name?.trim() || projectName(path);
  }

  /// Eén antwoord op "wat vraagt deze sessie van je" (AgentAttention): toestemming, vraag, fout, limiet, werk.
  function runItem(r: WorkspaceRun): Item {
    const key = `run:${r.id}`;
    let status: Status;
    if (agents.approvalFor(key) || r.status === "waitingApproval") status = "waiting";
    else if (agents.questionFor(key) && isActive(r.status)) status = "input";
    else if (r.status === "failed") status = r.limitedAt ? "limited" : "failed";
    else if (isActive(r.status)) status = "working";
    else if (r.status === "stopped") status = "finished";
    else status = "idle";
    return {
      id: key,
      folder: projectLabel(r.projectPath),
      title: r.title,
      branch: r.branch,
      agent: workspace.provider(r.provider)?.name ?? r.provider,
      status,
      compacting: false,
      started: isActive(r.status) ? (r.turnStartedAt ?? r.createdAt) : r.updatedAt,
      path: r.workingDirectory,
      unseen: r.status === "completed" && unseen(key, r.updatedAt),
      added: r.linesAdded ?? 0,
      removed: r.linesRemoved ?? 0,
      scratch: isScratch(r.projectPath),
      root: r.repoRoot ?? r.projectPath,
      otherProjects: r.otherProjects ?? [],
    };
  }

  function liveItem(s: AgentSession): Item {
    let status: Status = "idle";
    if (s.approvalId || s.status === "waiting") status = "waiting";
    else if (s.questionId) status = "input";
    else if (s.status === "running") status = "working";
    else if (s.status === "failed") status = "failed";
    const known = (agents.history?.sessions ?? []).find((p) => p.sessionId && p.sessionId === s.sessionId);
    return {
      id: s.id,
      folder: s.project,
      title: s.summary || known?.title || s.lastPrompt || s.project,
      branch: known?.branch || null,
      agent: s.name,
      status,
      compacting: Boolean(s.compacting),
      started: status === "idle" ? (s.updated ?? s.started) : s.started,
      path: s.cwd,
      unseen: s.status === "done" && unseen(s.id, s.updated),
      added: s.linesAdded,
      removed: s.linesRemoved,
      scratch: isScratch(s.cwd),
      root: s.cwd,
      otherProjects: [],
    };
  }

  const attentionOf: Record<Status, Attention> = {
    waiting: "approval", input: "input", failed: "failed", limited: "limited", working: "working", idle: "idle", finished: "finished",
  };
  const all = $derived([...runs.map(runItem), ...live.map(liveItem)]);
  const byId = $derived(new Map(all.map((i) => [i.id, i])));

  // The projects' own icons (`ProjectFavicons`): looked up once per folder; the initials until one is found.
  let favicons = $state<Record<string, string | null>>({});
  $effect(() => {
    for (const root of new Set(all.filter((i) => !i.scratch && i.root).map((i) => i.root))) {
      if (root in favicons) continue;
      favicons[root] = null;
      workspaceApi.favicon(root).then((url) => { if (url) favicons[root] = url; }).catch(() => {});
    }
  });
  // Search across sessions (`TimelineSearch`, #1498): the words also find sessions by what was said in them, and older
  // and archived sessions show under the list with the words around the match.
  let hits = $state<{ runId: string; snippet: string; archived: boolean }[]>([]);
  $effect(() => {
    const q = query.trim();
    if (q.length < 2) { hits = []; return; }
    const timer = setTimeout(() => workspaceApi.search(q).then((h) => { if (query.trim() === q) hits = h; }).catch(() => (hits = [])), 200);
    return () => clearTimeout(timer);
  });
  const hitIds = $derived(new Set(hits.map((h) => `run:${h.runId}`)));
  const allRows = $derived(all.map((i): inbox.InboxRow => ({
    id: i.id, title: i.title, project: i.folder, attention: i.unseen && i.status === "idle" ? "ready" : attentionOf[i.status],
    lastActivity: Date.parse(i.started ?? "") || 0, unread: i.unseen,
  })));
  // Settings › Sessions › Tidying up (`AutoSettlePolicy` on the Mac, `lib/auto-settle.ts`): quiet sessions move to Done
  // by themselves; checked as the list changes and every 30 s with `now`, so a change in Settings counts soon.
  $effect(() => {
    const result = autoSettle(allRows, inboxState, loadAutoSettleRules(), loadAutoSettled(), now);
    if (!result.settled.length) return;
    saveAutoSettled(result.autoSettled);
    untrack(() => update(result.state));
  });
  const rows = $derived.by(() => {
    const byTitle = inbox.filterRows(allRows, query);
    const kept = new Set(byTitle.map((r) => r.id));
    return [...byTitle, ...allRows.filter((r) => !kept.has(r.id) && hitIds.has(r.id))];
  });
  /** Matches outside the list: older sessions and archived ones. */
  const elsewhere = $derived(hits.filter((h) => !byId.has(`run:${h.runId}`)).map((h) => ({ hit: h, run: workspace.run(h.runId) })).filter((x) => !!x.run));
  const list = $derived(inbox.sections(rows, inboxState, { showWorking: view.showWorking && !inboxState.groupByProject, now, settledLimit, selectedId: agents.selectedId }));
  const groups = $derived(inboxState.groupByProject ? inbox.projectGroups(list) : []);
  const shelves = $derived(list.filter((s) => (inboxState.groupByProject ? s.kind !== "working" && s.kind !== "active" : true)));
  const shelfTitle = $derived<Record<inbox.SectionKind, string>>({
    pinned: tr("Vastgezet", "Pinned"), active: tr("Actief", "Active"), working: tr("Bezig", "Working"), snoozed: tr("Gesnoozed", "Snoozed"), settled: tr("Afgerond", "Done"),
  });
  const items = $derived(rows);
  const earlier = $derived(past.filter((p) => !query.trim() || `${p.title} ${p.cwd} ${agentNames[p.agent]}`.toLowerCase().includes(query.trim().toLowerCase())));

  const pages = ["pulls", "actions", "usage", "terminals", "browser", "worktrees"] as const;
  type Page = (typeof pages)[number];

  /// Wat rechts staat. Zonder keuze (of als die weg is): wat op je wacht of werkt, anders de plek om te starten.
  // Usage is a modal over what was open (the Mac's `UsageModal`), not a page of its own: behind it stays the last other
  // choice, and closing it goes back there.
  let behindUsage = $state<string | null>(agents.selectedId === "usage" ? null : agents.selectedId);
  $effect(() => {
    const id = agents.selectedId;
    if (id !== "usage") behindUsage = id;
  });
  const shownId = $derived(agents.selectedId === "usage" ? behindUsage : agents.selectedId);

  const selected = $derived.by(() => {
    const id = shownId;
    if (id === "new") return { kind: "new" as const };
    if (id && (pages as readonly string[]).includes(id)) return { kind: "page" as const, page: id as Page };
    if (id?.startsWith("past:")) {
      const key = id.slice(5);
      const p = past.find((s) => `${s.agent}:${s.sessionId}` === key) ?? (agents.history?.sessions ?? []).find((s) => `${s.agent}:${s.sessionId}` === key);
      if (p) return { kind: "past" as const, past: p };
    }
    if (id?.startsWith("run:") && workspace.run(id)) return { kind: "run" as const, id: id.slice(4) };
    const s = live.find((x) => x.id === id);
    if (s) return { kind: "live" as const, live: s };
    const activeRun = runs.find((r) => isActive(r.status));
    if (activeRun) return { kind: "run" as const, id: activeRun.id };
    const busy = live.find((x) => x.status === "waiting" || x.approvalId || x.status === "running");
    if (busy) return { kind: "live" as const, live: busy };
    return { kind: "new" as const };
  });

  const currentId = $derived(
    selected.kind === "run" ? `run:${selected.id}` : selected.kind === "live" ? selected.live.id : selected.kind === "past" ? `past:${selected.past.agent}:${selected.past.sessionId}` : selected.kind === "page" ? selected.page : "new",
  );

  // Kijken naar een sessie telt als gezien hebben wat hij afmaakte; weggaan ook.
  let lastSeen = "";
  $effect(() => {
    const id = currentId;
    if (id === lastSeen) return;
    if (lastSeen) agents.visit(lastSeen);
    lastSeen = id;
    agents.visit(id);
  });

  async function takeover(s: AgentSession, endTerminal: boolean, message?: string) {
    if (endTerminal && !(await ask({
      question: tr("{name} in {project} beëindigen en hier verdergaan?", "End {name} in {project} and continue here?", { name: s.name, project: s.project }),
      detail: tr("De agent bewaart zijn gesprek, zodat Nook verdergaat waar hij was.", "The agent keeps its conversation, so Nook picks up where it left off."),
      confirmTitle: tr("Beëindig en ga hier verder", "End and continue here"),
    }))) return;
    try {
      const id = await workspaceApi.continueLive(s.id, message ?? null, endTerminal);
      await workspace.refresh();
      agents.select(`run:${id}`);
    } catch (e) {
      agents.error = String(e);
    }
  }

  async function continuePast(p: PastSession, message?: string) {
    try {
      const id = await workspaceApi.continuePast(`${p.agent}:${p.sessionId}`, message ?? null);
      await workspace.refresh();
      agents.select(`run:${id}`);
    } catch (e) {
      agents.error = String(e);
    }
  }

  /// The status as the Mac's `AgentStatusBadge` shows it (`AgentStatusStyle`): one word, one symbol and one tone per state;
  /// a row that asks nothing shows how long ago instead.
  type Badge = { word: string; icon: string | null; tone: "amber" | "coral" | "blue" | "mint" | "muted"; detail?: string };
  function badgeOf(i: Item): Badge | null {
    if (i.compacting) return { word: tr("Samenvatten…", "Compacting…"), icon: null, tone: "blue" };
    switch (i.status) {
      case "waiting": return { word: tr("Goedkeuring", "Approval"), icon: "shield-half", tone: "amber" };
      case "input": return { word: tr("Antwoord", "Answer"), icon: "message-circle-question", tone: "amber" };
      case "failed": return { word: tr("Mislukt", "Failed"), icon: "circle-alert", tone: "coral" };
      case "limited": return { word: tr("Limiet", "Limit"), icon: "clock", tone: "amber" };
      case "working": return { word: tr("Bezig", "Working"), icon: null, tone: "blue", detail: i.started ? ago(i.started, now) : undefined };
      default: return i.unseen ? { word: tr("Klaar", "Ready"), icon: "circle-check", tone: "mint" } : null;
    }
  }

  /// "Add project" palette (`AddProjectPalette` on macOS, #1482, AG-113): new empty Git project, local folder, Git URL, or GitHub owner/repo.
  let addingProject = $state(false);

  function openProjectSettings() {
    try { localStorage.setItem("settings.section", "projects"); } catch { /* opens on the last page instead */ }
    api.showMain("settings");
  }

  /// Escape closes the innermost menu or selection first.
  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") {
      if (addingProject) { e.preventDefault(); addingProject = false; return; }
      if (customSnoozeFor) { e.preventDefault(); customSnoozeFor = null; return; }
      if (menuFor) { e.preventDefault(); menuFor = null; return; }
      if (projectMenu) { e.preventDefault(); projectMenu = null; return; }
      if (picked.size || selecting) { e.preventDefault(); picked = new Set(); selecting = false; return; }
    }
  }

  // The session commands (`OpenSessionActions`): they come from the rules in `lib/keybindings.ts`, so a key you
  // rebound in Settings › Shortcuts works here too.
  const openId = () => (byId.get(currentId) ? currentId : null);
  $effect(() => onCommands({
    "session.settle": () => {
      const id = openId();
      if (!id) return false;
      update(inboxState.settled.includes(id) ? inbox.unsettle(inboxState, id) : inbox.settle(inboxState, id));
    },
    "session.pin": () => {
      const id = openId();
      if (!id) return false;
      update(inboxState.pinned.includes(id) ? inbox.unpin(inboxState, id) : inbox.pin(inboxState, id));
    },
    "session.undo": () => undoLast(),
    "session.copyReference": () => {
      const row = byId.get(currentId);
      if (!row) return false;
      navigator.clipboard.writeText(row.path).catch(() => {});
    },
    "session.openInEditor": () => {
      const row = byId.get(currentId);
      if (!row?.path) return false;
      workspaceApi.openIn(row.path).catch((err) => (agents.error = String(err)));
    },
    "session.rename": () => {
      if (!currentId.startsWith("run:")) return false;
      window.dispatchEvent(new CustomEvent("nook-agents-rename", { detail: currentId }));
    },
    "modelPicker.toggle": () => { window.dispatchEvent(new CustomEvent("nook-agents-picker", { detail: "model" })); },
    "effortPicker.toggle": () => { window.dispatchEvent(new CustomEvent("nook-agents-picker", { detail: "model" })); },
    "permissionPicker.toggle": () => { window.dispatchEvent(new CustomEvent("nook-agents-picker", { detail: "access" })); },
  }));

  // Several rows at once (`ListSelection`): Ctrl-click adds or removes a row, Shift-click takes the rows in between.
  let picked = $state(new Set<string>());
  let selecting = $state(false);
  let lastClicked: string | null = null;
  let projectMenu = $state<{ root: string; folder: string; rowId?: string; x: number; y: number } | null>(null);
  const shownIds = $derived([...list.flatMap((sec) => sec.rows.map((r) => r.row.id))]);

  // Keep `picked` pruned when sessions disappear from the visible list.
  $effect(() => {
    if (!picked.size) return;
    const visible = new Set(shownIds);
    let dropped = false;
    for (const id of picked) if (!visible.has(id)) { dropped = true; break; }
    if (dropped) picked = new Set([...picked].filter((id) => visible.has(id)));
  });

  function clickRow(e: MouseEvent, id: string) {
    if (e.ctrlKey || e.metaKey || (selecting && !e.shiftKey)) {
      const next = new Set(picked);
      if (next.has(id)) next.delete(id); else next.add(id);
      picked = next;
      lastClicked = id;
      return;
    }
    if (e.shiftKey && lastClicked) {
      const a = shownIds.indexOf(lastClicked), b = shownIds.indexOf(id);
      if (a >= 0 && b >= 0) {
        picked = new Set([...picked, ...shownIds.slice(Math.min(a, b), Math.max(a, b) + 1)]);
        return;
      }
    }
    picked = new Set();
    lastClicked = id;
    agents.select(id);
  }

  // Archive and delete are for sessions Nook runs that are not working; deleting asks first, as the Mac does (AG-112).
  const pickedRuns = $derived([...picked].filter((id) => id.startsWith("run:")).map((id) => workspace.run(id)).filter((r): r is WorkspaceRun => !!r && !isActive(r.status)));
  const archivable = $derived(pickedRuns.filter((r) => !r.archived));
  const deletable = $derived(pickedRuns);

  async function archivePicked() {
    for (const r of archivable) await workspace.act(() => workspaceApi.archive(r.id, true));
    picked = new Set();
    selecting = false;
  }

  async function deletePicked() {
    const targets = deletable;
    if (!targets.length) return;
    const ok = await ask({
      question: targets.length === 1
        ? tr("1 sessie verwijderen?", "Delete 1 session?")
        : tr("{n} sessies verwijderen?", "Delete {n} sessions?", { n: targets.length }),
      detail: tr("De geselecteerde sessies worden definitief uit Nook verwijderd.", "The selected sessions will be permanently removed from Nook."),
      confirmTitle: tr("Verwijderen", "Delete"),
    });
    if (!ok) return;
    const removedIds = new Set(targets.map((r) => `run:${r.id}`));
    for (const r of targets) await workspace.act(() => workspaceApi.remove(r.id));
    let st = inboxState;
    for (const id of removedIds) {
      st = inbox.unpin(inbox.unsettle(inbox.wake(st, id), id), id);
    }
    update(st);
    if (removedIds.has(currentId)) agents.select(null);
    picked = new Set();
    selecting = false;
  }

  // Dropping files onto any session row (`AgentInboxList` on the Mac, AG-112): highlight the target row, open the
  // session, and pass the dropped paths into its composer.
  let dropTarget = $state<string | null>(null);

  function rowAtPoint(x: number, y: number): string | null {
    const el = document.elementFromPoint(x, y);
    return el?.closest<HTMLElement>("[data-session-row]")?.dataset.sessionRow ?? null;
  }

  function formatDroppedPaths(paths: string[]): string {
    return paths.map((p) => (/\s/.test(p) ? `"${p}"` : p)).join(" ");
  }

  function handleDropOnRow(id: string, rawPaths: string[]) {
    const paths = [...new Set(rawPaths.map((p) => p.trim()).filter(Boolean))];
    if (!paths.length) return;
    agents.select(id);
    if (id.startsWith("run:")) {
      composerInbox.add(formatDroppedPaths(paths), id);
    } else {
      agents.queueDroppedFiles(id, paths);
    }
    window.dispatchEvent(new CustomEvent("nook-agents-drop-files", { detail: { id, paths } }));
  }

  function pathsFromDataTransfer(dt: DataTransfer | null): string[] {
    if (!dt) return [];
    const found: string[] = [];
    for (const f of Array.from(dt.files ?? [])) {
      const path = (f as File & { path?: string }).path || f.name;
      if (path) found.push(path);
    }
    if (!found.length) {
      const uriList = dt.getData("text/uri-list");
      if (uriList) {
        for (const line of uriList.split(/\r?\n/)) {
          const t = line.trim();
          if (!t || t.startsWith("#")) continue;
          found.push(t.startsWith("file://") ? decodeURIComponent(t.replace(/^file:\/\//, "")) : t);
        }
      }
    }
    return found;
  }

  $effect(() => {
    let active = true;
    let unlisten: (() => void) | null = null;
    try {
      getCurrentWebview()
        .onDragDropEvent((event) => {
          if (!active) return;
          const payload = event.payload;
          const dpr = window.devicePixelRatio || 1;
          if (payload.type === "enter" || payload.type === "over") {
            dropTarget = rowAtPoint(payload.position.x / dpr, payload.position.y / dpr);
          } else if (payload.type === "drop") {
            const target = rowAtPoint(payload.position.x / dpr, payload.position.y / dpr) ?? dropTarget;
            dropTarget = null;
            if (target && payload.paths?.length) handleDropOnRow(target, payload.paths);
          } else {
            dropTarget = null;
          }
        })
        .then((fn) => {
          if (active) unlisten = fn;
          else fn();
        })
        .catch(() => {});
    } catch {
      // Running outside Tauri webview (e.g. unit tests) — HTML5 drag handlers remain active.
    }
    return () => {
      active = false;
      dropTarget = null;
      unlisten?.();
    };
  });

  /// Settings › Coding agents, from the empty list.
  function setUpAgents() {
    try { localStorage.setItem("settings.section", "agents"); } catch { /* opens on the last page instead */ }
    api.showMain("settings");
  }
</script>

<svelte:window onkeydown={keys} />

<div class="tab" class:compact class:docked>
  <aside use:dock class:docked>
    <div class="head">
      <!-- The Mac's head of the session list: a quiet search (`NookSearchField`, ghost), then the view menu, permissions,
           add project and new session as header icons (`PanelHeaderIcon`), lit only while what they stand for is on. -->
      <label class="search"><Ico name="search" size={15} /><input placeholder={tr("Zoek in sessies", "Search sessions")} aria-label={tr("Zoek in sessies", "Search sessions")} bind:value={query} /></label>
      <Dropdown width={240} below align="right" label={tr("Filteren en groeperen", "Filter and group")}>
        {#snippet trigger({ toggle, open })}
          <button class="head-icon" class:on={open || view.projectFolders || !view.showWorking} onclick={toggle} aria-expanded={open}
            title={tr("Filteren en groeperen", "Filter and group")} aria-label={tr("Filteren en groeperen", "Filter and group")}><Ico name="list-filter" size={16} /></button>
        {/snippet}
        {#snippet children()}
          <div class="dd-header">{tr("Filteren en groeperen", "Filter and group")}</div>
          <DropdownRow symbol="folder" title={tr("Groeperen per project", "Group by project")} trailing={view.projectFolders ? "✓" : undefined} chosen={view.projectFolders}
            onclick={() => setView({ ...view, projectFolders: !view.projectFolders })} />
          <DropdownRow symbol="zap" title={tr("Aan het werk apart tonen", "Show working separately")} trailing={view.showWorking ? "✓" : undefined} chosen={view.showWorking}
            onclick={() => setView({ ...view, showWorking: !view.showWorking })} />
          <div class="dd-sep"></div>
          <DropdownRow symbol="square-check" title={tr("Selecteer…", "Select…")} chosen={selecting}
            onclick={() => { selecting = !selecting; if (!selecting) picked = new Set(); }} />
          <DropdownRow symbol="shield-check" title={tr("Opgeslagen regels…", "Granted rules…")}
            onclick={() => (permissionsSheet = { project: null, tab: "rules" })} />
          <DropdownRow symbol="history" title={tr("Geschiedenis van goedkeuringen…", "Approval log…")}
            onclick={() => (permissionsSheet = { project: null, tab: "audit" })} />
        {/snippet}
      </Dropdown>
      <button class="head-icon" class:on={!!permissionsSheet} title={tr("Toestemmingen", "Permissions")} aria-label={tr("Toestemmingen", "Permissions")} onclick={() => (permissionsSheet = { project: null, tab: "rules" })}><Ico name="shield-check" size={16} /></button>
      <button class="head-icon" class:on={addingProject} title={tr("Project toevoegen", "Add project")} aria-label={tr("Project toevoegen", "Add project")} onclick={() => (addingProject = true)}><Ico name="folder-plus" size={16} /></button>
      <button class="head-icon" class:on={selected.kind === "new"} title={tr("Nieuwe sessie", "New session")} aria-label={tr("Nieuwe sessie", "New session")} onclick={() => agents.select("new")}><Ico name="square-pen" size={16} /></button>
    </div>
    <div class="list">
      {#snippet entryRow(entry: InboxEntry, kind: inbox.SectionKind)}
        {@const i = byId.get(entry.row.id)}
        {#if i}
          {@const badge = kind === "snoozed" || entry.woke ? null : badgeOf(i)}
          {@const prSummary = prSync.forSession(i.id.startsWith("run:") ? i.id.slice(4) : null, i.path, i.branch)}
          {@const meta = !!i.branch || i.added + i.removed > 0 || !!prSummary.badge}
          <div
            class="rowwrap"
            data-session-row={i.id}
            role="presentation"
            ondragover={(e) => { if (e.dataTransfer?.types?.length) { e.preventDefault(); dropTarget = i.id; } }}
            ondragleave={(e) => { if (dropTarget === i.id && !(e.currentTarget as HTMLElement).contains(e.relatedTarget as Node | null)) dropTarget = null; }}
            ondrop={(e) => { e.preventDefault(); dropTarget = null; const paths = pathsFromDataTransfer(e.dataTransfer); if (paths.length) handleDropOnRow(i.id, paths); }}
          >
            <!-- A session row (`AgentListRow` in `AgentRowLayout`): the project's badge and name with the status or how long
                 ago; the session's name; its branch with the agent's logo at the end (beside the name when there is no branch). -->
            <button class="row" class:on={currentId === i.id} class:receded={entry.receded} class:picked={picked.has(i.id)} class:drop-target={dropTarget === i.id}
              onclick={(e) => clickRow(e, i.id)} oncontextmenu={(e) => { if (!i.scratch && i.root) { e.preventDefault(); projectMenu = { root: i.root, folder: i.folder, rowId: i.id, x: e.clientX, y: e.clientY }; } }}>
              <span class="line0">
                {#if selecting || picked.size > 0}
                  <span class="sel-box" class:checked={picked.has(i.id)} aria-hidden="true">
                    <Ico name={picked.has(i.id) ? "square-check" : "circle"} size={13} />
                  </span>
                {/if}
                {#if i.scratch}
                  <span class="badge-mark dashed"><Ico name="square-dashed" size={12} stroke={2.4} /></span>
                  <span class="folder" title={i.path}>{tr("Geen project", "No project")}</span>
                {:else}
                  <span class="badge-mark">{#if favicons[i.root]}<img class="favicon" src={favicons[i.root]} alt="" width="18" height="18" />{:else}<ProjectIconView name={i.folder} size={18} />{/if}</span>
                  <span class="folder" title={[i.path, ...i.otherProjects].join("\n")}>{multiProjectLabel(i.folder, i.otherProjects)}</span>
                {/if}
                <span class="spacer"></span>
                <span class="slot">
                  {#if dropTarget === i.id}<span class="status blue"><Ico name="file" size={11} stroke={2.5} />{tr("Zet neer", "Drop here")}</span>
                  {:else if kind === "snoozed"}<span class="status muted"><Ico name="bell-off" size={11} stroke={2.5} />{tr("tot {time}", "until {time}", { time: new Date(inboxState.snoozed[i.id]).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }) })}</span>
                  {:else if entry.woke}<span class="status amber"><Ico name="alarm-clock" size={11} stroke={2.5} />{tr("Wakker", "Awake")}</span>
                  {:else if badge}<span class="status {badge.tone}">{#if badge.icon}<Ico name={badge.icon} size={11} stroke={2.5} />{:else}<span class="pulse"></span>{/if}{badge.word}{#if badge.detail}<span class="num">{badge.detail}</span>{/if}</span>
                  {:else}<span class="ago">{ago(i.started, now)}</span>{/if}
                </span>
              </span>
              <span class="line1"><span class="title">{i.title}</span>{#if !meta}<span class="spacer"></span><span class="logo"><AgentMark agent={i.agent} size={14} /></span>{/if}</span>
              {#if i.compacting}
                <span class="compacting-line">{tr("Het gesprek wordt samengevat…", "Compacting the conversation…")}</span>
              {/if}
              {#if meta}
                <!-- The branch, PR badge + hover card (AG-104), what the session changed ("+120 −8"), then the agent's logo. -->
                <span class="line2">{#if i.branch}<span class="branch">{i.branch}</span>{/if}{#if prSummary.badge}<PullRequestPill badge={prSummary.badge} current={prSummary.current} earlier={prSummary.earlier} onopen={(link) => openPrFromRow(i.id, link)} />{/if}<span class="spacer"></span>{#if i.added + i.removed > 0}<span class="lines" class:dim={i.status === "finished"}><span class="plus">+{i.added}</span><span class="minus">−{i.removed}</span></span>{/if}<span class="logo"><AgentMark agent={i.agent} size={14} /></span></span>
              {/if}
            </button>
            <!-- On hover the status gives way to the row's buttons (`hoverActions`): snooze, pin and settle. -->
            <span class="row-actions">
              {#if kind === "snoozed"}
                <button class="row-action" title={tr("Wakker maken", "Wake up")} aria-label={tr("Wakker maken", "Wake up")} onclick={(e) => { e.stopPropagation(); update(inbox.wake(inboxState, i.id)); }}><Ico name="alarm-clock" size={13} /></button>
              {:else if !needsYou(entry.row.attention)}
                <button class="row-action" class:lit={menuFor === i.id} title={tr("Snooze", "Snooze")} aria-label={tr("Snooze", "Snooze")} onclick={(e) => { e.stopPropagation(); menuFor = menuFor === i.id ? null : i.id; }}><Ico name="clock" size={13} /></button>
              {/if}
              {#if inboxState.pinned.includes(i.id)}
                <button class="row-action" title={tr("Los maken", "Unpin")} aria-label={tr("Los maken", "Unpin")} onclick={(e) => { e.stopPropagation(); update(inbox.unpin(inboxState, i.id)); }}><Ico name="pin-off" size={13} /></button>
              {:else}
                <button class="row-action" title={tr("Vastzetten", "Pin")} aria-label={tr("Vastzetten", "Pin")} onclick={(e) => { e.stopPropagation(); update(inbox.pin(inboxState, i.id)); }}><Ico name="pin" size={13} /></button>
              {/if}
              {#if inboxState.settled.includes(i.id)}
                <button class="row-action" title={tr("Heropenen", "Reopen")} aria-label={tr("Heropenen", "Reopen")} onclick={(e) => { e.stopPropagation(); update(inbox.unsettle(inboxState, i.id)); }}><Ico name="rotate-ccw" size={13} /></button>
              {:else}
                <button class="row-action" title={tr("Afronden", "Mark as done")} aria-label={tr("Afronden", "Mark as done")} onclick={(e) => { e.stopPropagation(); update(inbox.settle(inboxState, i.id)); }}><Ico name="check" size={13} /></button>
              {/if}
            </span>
            {#if menuFor === i.id}
              <div class="menu" role="menu">
                <!-- Your snooze options (Settings › Notifications), the ones still ahead now. -->
                {#each snoozeMenu(loadOptions(), new Date(now)) as c (optionId(c.option))}
                  <button role="menuitem" onclick={() => update(inbox.snooze(inboxState, i.id, c.end.getTime()))}>{optionLabel(c.option)}</button>
                {/each}
                <hr />
                <!-- "Pick a time…" (`SnoozeMenuItems` / `CustomSnoozeSheet`): custom duration or exact date & time. -->
                <button role="menuitem" class="pick-time" onclick={() => openCustomSnooze(i.id)}>
                  <Ico name="clock" size={13} />
                  {tr("Kies een tijdstip…", "Pick a time…")}
                </button>
              </div>
            {/if}
          </div>
        {/if}
      {/snippet}
      {#each shelves.filter((s) => s.kind === "pinned") as shelf (shelf.kind)}
        <p class="section">{shelfTitle[shelf.kind]}</p>
        {#each shelf.rows as entry (entry.row.id)}{@render entryRow(entry, shelf.kind)}{/each}
      {/each}
      {#if inboxState.groupByProject}
        {#each groups as group (group.project)}
          {@const folded = inboxState.collapsedProjects.includes(group.project) && !query.trim()}
          {@const firstItem = group.rows.map((r) => byId.get(r.entry.row.id)).find((x) => x && !x.scratch && x.root)}
          <button
            class="project"
            class:ask={group.needsYou}
            aria-expanded={!folded}
            onclick={() => update(inbox.toggleProject(inboxState, group.project))}
            oncontextmenu={(e) => {
              if (firstItem) {
                e.preventDefault();
                projectMenu = { root: firstItem.root, folder: group.project || firstItem.folder, x: e.clientX, y: e.clientY };
              }
            }}
          >
            <span class="chev">{folded ? "▸" : "▾"}</span>
            {#if firstItem}
              <span class="badge-mark">
                {#if favicons[firstItem.root]}
                  <img class="favicon" src={favicons[firstItem.root]} alt="" width="16" height="16" />
                {:else}
                  <ProjectIconView name={group.project || firstItem.folder} size={16} />
                {/if}
              </span>
            {/if}
            <span class="pname">{group.project || tr("geen map", "no folder")}</span>
            <span class="spacer"></span>{#if folded && group.needsYou}<span class="dot waiting"></span>{/if}<span class="faint count">{group.rows.length}</span>
          </button>
          {#each group.rows.filter((r) => !folded || r.entry.row.id === currentId) as r (r.entry.row.id)}{@render entryRow(r.entry, r.kind)}{/each}
        {/each}
      {/if}
      {#each shelves.filter((s) => s.kind !== "pinned") as shelf (shelf.kind)}
        <!-- Active rows stand without a header, as on the Mac; the other shelves get theirs (`NookShelfHeader`). -->
        {#if shelf.kind !== "active"}<p class="section"><span>{shelfTitle[shelf.kind]}</span><span class="count">{shelf.rows.length + shelf.hiddenCount}</span></p>{/if}
        {#each shelf.rows as entry (entry.row.id)}{@render entryRow(entry, shelf.kind)}{/each}
        {#if shelf.hiddenCount > 0}
          <button class="section toggle" onclick={() => (settledLimit += inbox.settledPage)}>{tr("Toon {n} meer", "Show {n} more", { n: Math.min(inbox.settledPage, shelf.hiddenCount) })}</button>
        {/if}
      {/each}
      {#if elsewhere.length}
        <p class="section"><span>{tr("Ook gevonden", "Also found")}</span><span class="count">{elsewhere.length}</span></p>
        {#each elsewhere as { hit, run: r } (hit.runId)}
          <button class="row slim" class:on={currentId === `run:${hit.runId}`} onclick={() => agents.select(`run:${hit.runId}`)}>
            <span class="line1"><span class="title">{r!.title}</span>{#if hit.archived}<span class="spacer"></span><span class="ago">{tr("gearchiveerd", "archived")}</span>{/if}</span>
            {#if hit.snippet}<span class="line2 snippet">{hit.snippet}</span>{/if}
          </button>
        {/each}
      {/if}
      {#if earlier.length}
        <button class="section toggle" onclick={() => (showFinished = !showFinished)}>{tr("Afgerond ({n})", "Done ({n})", { n: earlier.length })} {showFinished ? "▾" : "▸"}</button>
        {#if showFinished}
          {#each earlier as p (p.agent + p.sessionId)}
            <button class="row slim" class:on={currentId === `past:${p.agent}:${p.sessionId}`} onclick={() => agents.select(`past:${p.agent}:${p.sessionId}`)}>
              <span class="line1">{p.title || tr("Sessie zonder titel", "Untitled session")}</span>
              <span class="line2 faint">{folderName(p.cwd)} · {agentNames[p.agent]} · {ago(p.ended, now)}</span>
            </button>
          {/each}
        {/if}
      {/if}
      {#if !list.length && !earlier.length}
        {#if agents.history}
          <!-- The Mac's empty list (`WSEmptyState`): what shows up here, and the way to set agents up. -->
          <EmptyState symbol="terminal" title={tr("Er werkt nu geen agent", "No agent is working right now")}
            message={tr("Start Claude Code, Codex of Gemini in je terminal en hij verschijnt hier vanzelf.", "Start Claude Code, Codex or Gemini in your terminal and it shows up here by itself.")}
            action={{ title: tr("Coding-agents instellen", "Set up coding agents"), run: setUpAgents }} />
        {:else}
          <p class="faint empty">{tr("Even kijken…", "Just a moment…")}</p>
        {/if}
      {/if}
    </div>
    {#if undoNotice}
      <div class="undo-line" role="status">
        <span>{undoText(undoNotice)}{#if undoKey} · <kbd>{chordLabel(undoKey)}</kbd>{/if}</span>
        <span class="spacer"></span>
        <button class="ghost" onclick={() => undoLast()}>{tr("Ongedaan maken", "Undo")}</button>
      </div>
    {/if}
    {#if picked.size || selecting}
      <!-- The selection bar (`SelectionBar`): Ctrl-click or Shift-click rows, then act on all of them at once. -->
      <div class="selection">
        <div class="sel-head">
          <strong>{picked.size ? tr("{n} geselecteerd", "{n} selected", { n: picked.size }) : tr("Kies rijen", "Pick rows")}</strong>
          <span class="spacer"></span>
          <button class="ghost" onclick={() => (picked = picked.size === shownIds.length ? new Set() : new Set(shownIds))}>{picked.size === shownIds.length ? tr("Wissen", "Clear") : tr("Selecteer alles", "Select all")}</button>
          <button class="ghost" onclick={() => { picked = new Set(); selecting = false; }}>{tr("Klaar", "Done")}</button>
        </div>
        <div class="sel-actions">
          {#if [...picked].every((id) => inboxState.pinned.includes(id))}
            <button class="ghost" disabled={!picked.size} onclick={() => { let st = inboxState; for (const id of picked) st = inbox.unpin(st, id); update(st); }}><Ico name="pin-off" size={14} />{tr("Maak los", "Unpin")}</button>
          {:else}
            <button class="ghost" disabled={!picked.size} onclick={() => { let st = inboxState; for (const id of [...picked].reverse()) st = inbox.pin(st, id); update(st); }}><Ico name="pin" size={14} />{tr("Zet vast", "Pin")}</button>
          {/if}
          {#if picked.size && [...picked].every((id) => inboxState.settled.includes(id))}
            <button class="ghost" onclick={() => { let st = inboxState; for (const id of picked) st = inbox.unsettle(st, id); update(st); }}><Ico name="rotate-ccw" size={14} />{tr("Zet weer open", "Reopen")}</button>
          {:else}
            <button class="ghost" disabled={!picked.size} onclick={() => { let st = inboxState; for (const id of picked) st = inbox.settle(st, id); update(st); }}><Ico name="check" size={14} />{tr("Handel af", "Settle")}</button>
          {/if}
          <button class="ghost" disabled={!archivable.length} onclick={archivePicked}><Ico name="archive" size={14} />{tr("Archiveer", "Archive")}</button>
          <span class="spacer"></span>
          <button class="ghost danger" disabled={!deletable.length} onclick={deletePicked}><Ico name="trash-2" size={14} />{tr("Verwijderen", "Delete")}</button>
        </div>
      </div>
    {/if}
  </aside>
  {#if projectMenu}
    {@const pm = projectMenu}
    <!-- The Project menu (`projectMenu`): from any session row or project group header. -->
    <div class="ctx-backdrop" role="presentation" onclick={() => (projectMenu = null)} oncontextmenu={(e) => { e.preventDefault(); projectMenu = null; }}></div>
    <div class="menu ctx" role="menu" style:left="{pm.x}px" style:top="{pm.y}px">
      <div class="ctx-head">{tr("Project {name}", "Project {name}", { name: pm.folder })}</div>
      <button role="menuitem" onclick={() => { projectMenu = null; openNewSessionIn(pm.root); }}>{tr("Nieuwe sessie in {name}", "New session in {name}", { name: pm.folder })}</button>
      <button role="menuitem" onclick={() => { projectMenu = null; workspaceApi.toggleFavoriteProject(pm.root).then(() => workspace.refresh()); }}>{(workspace.settings?.favoriteProjects ?? []).includes(pm.root) ? tr("Verwijder uit favorieten", "Remove from favorites") : tr("Voeg toe aan favorieten", "Add to favorites")}</button>
      <button role="menuitem" onclick={() => { projectMenu = null; revealItemInDir(pm.root).catch(() => {}); }}>{tr("Toon in Verkenner", "Show in Explorer")}</button>
      <button role="menuitem" onclick={() => { projectMenu = null; toolsApi.openTerminal(pm.root).catch((err) => (agents.error = String(err))); }}>{tr("Open in terminal", "Open in terminal")}</button>
      <button role="menuitem" onclick={() => { projectMenu = null; navigator.clipboard.writeText(pm.root).catch(() => {}); }}>{tr("Kopieer pad", "Copy path")}</button>
      <button role="menuitem" onclick={() => { projectMenu = null; permissionsSheet = { project: pm.root, tab: "rules" }; }}>{tr("Opgeslagen regels…", "Granted rules…")}</button>
      <button role="menuitem" onclick={() => { projectMenu = null; openProjectSettings(); }}>{tr("Projectinstellingen…", "Project settings…")}</button>
      {#if pm.rowId}
        <hr />
        <button role="menuitem" onclick={() => { projectMenu = null; selecting = true; picked = new Set([pm.rowId!]); }}>{tr("Selecteer…", "Select…")}</button>
      {/if}
    </div>
  {/if}
  {#if addingProject}
    <AddProjectPalette
      onadded={(folder) => {
        addingProject = false;
        openNewSessionIn(folder);
      }}
      onclose={() => (addingProject = false)}
    />
  {/if}
  <section class="main" class:thread={selected.kind === "run" || selected.kind === "live" || selected.kind === "past"} class:page={selected.kind === "page" && selected.page !== "browser" && selected.page !== "worktrees"}>
    {#if agents.error}<p class="err">{agents.error} <button class="ghost" onclick={() => (agents.error = null)}>✕</button></p>{/if}
    {#if selected.kind === "run"}
      {#key selected.id}<RunPanel runId={selected.id} ongone={() => agents.select(null)} />{/key}
    {:else if selected.kind === "live"}
      {#key selected.live.id}<LiveDetail session={selected.live} ontakeover={takeover} />{/key}
    {:else if selected.kind === "past"}
      {#key selected.past.sessionId}<PastDetail session={selected.past as PastSession} oncontinue={continuePast} />{/key}
    {:else if selected.kind === "page"}
      {#if selected.page === "pulls"}<PullRequests />
      {:else if selected.page === "actions"}<Actions />
      {:else if selected.page === "terminals"}<Terminals page />
      {:else if selected.page === "browser"}<Browser />
      {:else}<Worktrees />{/if}
    {:else}
      <NewSession onstarted={(id) => agents.select(`run:${id}`)} />
    {/if}
  </section>
  {#if agents.selectedId === "usage"}<UsageModal onclose={() => agents.select(behindUsage)} />{/if}
  {#if permissionsSheet}
    <GrantedRulesSheet project={permissionsSheet.project} initialTab={permissionsSheet.tab ?? "rules"} onclose={() => (permissionsSheet = null)} />
  {/if}
  {#if customSnoozeFor}
    <div class="snooze-backdrop" role="presentation" onclick={() => (customSnoozeFor = null)}>
      <div class="snooze-sheet" role="dialog" aria-modal="true" aria-label={tr("Snooze tot", "Snooze until")} tabindex="-1" onclick={(e) => e.stopPropagation()} onkeydown={() => {}}>
        <form class="snooze-form" onsubmit={(e) => { e.preventDefault(); applyCustomSnooze(); }}>
          <div class="snooze-head">
            <h3>{tr("Snooze tot", "Snooze until")}</h3>
            <span class="spacer"></span>
            <button type="button" class="head-icon" onclick={() => (customSnoozeFor = null)} aria-label={tr("Sluit", "Close")}><Ico name="x" size={15} /></button>
          </div>
          <div class="snooze-tabs" role="tablist">
            <button type="button" role="tab" aria-selected={customSnoozeMode === "duration"} class:on={customSnoozeMode === "duration"} onclick={() => (customSnoozeMode = "duration")}>{tr("Duur", "Duration")}</button>
            <button type="button" role="tab" aria-selected={customSnoozeMode === "datetime"} class:on={customSnoozeMode === "datetime"} onclick={() => (customSnoozeMode = "datetime")}>{tr("Datum en tijd", "Date & time")}</button>
          </div>
          {#if customSnoozeMode === "duration"}
            <div class="snooze-row">
              <input type="number" min="1" max="999" bind:value={customSnoozeAmount} aria-label={tr("Aantal", "Amount")} />
              <select bind:value={customSnoozeUnit} aria-label={tr("Eenheid", "Unit")}>
                <option value="minutes">{tr("minuten", "minutes")}</option>
                <option value="hours">{tr("uur", "hours")}</option>
                <option value="days">{tr("dagen", "days")}</option>
              </select>
            </div>
          {:else}
            <div class="snooze-row">
              <input type="datetime-local" bind:value={customSnoozeAt} min={localMoment(now)} aria-label={tr("Snooze tot", "Snooze until")} />
            </div>
          {/if}
          {#if customSnoozeTarget > now}
            <p class="snooze-preview">{tr("Gesnoozed tot {time}", "Snoozed until {time}", { time: formatSnoozePreview(customSnoozeTarget) })}</p>
          {:else}
            <p class="snooze-preview invalid">{tr("Kies een tijdstip in de toekomst.", "Choose a time in the future.")}</p>
          {/if}
          <div class="snooze-foot">
            <span class="spacer"></span>
            <button type="button" class="ghost" onclick={() => (customSnoozeFor = null)}>{tr("Annuleer", "Cancel")}</button>
            <button type="submit" class="primary" disabled={customSnoozeTarget <= now}>{tr("Snooze", "Snooze")}</button>
          </div>
        </form>
      </div>
    </div>
  {/if}
</div>

<style>
  .undo-line { display: flex; align-items: center; gap: var(--space-8); margin: var(--space-4) var(--space-8); padding: var(--space-6) var(--space-12); border-radius: var(--radius-card); background: var(--menu); border: 1px solid var(--line2); font: var(--text-detail); color: var(--text2); }
  .undo-line .spacer { flex: 1; }
  .tab { display: grid; grid-template-columns: 260px minmax(0, 1fr); height: 100%; min-height: 0; }
  .tab.compact { grid-template-columns: 250px 1fr; }
  .tab.docked { grid-template-columns: minmax(0, 1fr); }
  aside { border-right: 1px solid var(--border); display: flex; flex-direction: column; min-height: 0; padding: var(--space-8); gap: var(--space-8); }
  /* Docked in the sidebar: no column of its own, the sidebar's edge and padding are the list's. */
  aside.docked { border-right: 0; padding: 0; flex: 1; min-height: 0; }
  .head { display: flex; align-items: center; gap: var(--space-6); }
  .spacer { flex: 1; }
  /* `PanelHeaderIcon`: a 28 pt square, secondary at rest, paper on smoke under the pointer or while on. */
  .head-icon { display: grid; place-items: center; width: 28px; height: 28px; padding: 0; margin: 0; flex: none; border: 0; border-radius: var(--radius-control); background: transparent; color: var(--text2); }
  .head-icon.on, .head-icon:hover { background: var(--smoke); color: var(--paper); }
  /* `NookSearchField` in its ghost style: no field, a row fill under the pointer. */
  .search { flex: 1; min-width: 0; display: flex; align-items: center; gap: var(--space-8); height: 32px; padding: 0 var(--space-8); border-radius: var(--radius-control); color: var(--text3); }
  .search:hover { background: var(--row-hover); }
  .search input { flex: 1; min-width: 0; height: 100%; padding: 0; border: 0; background: transparent; box-shadow: none; outline: none; font: var(--text-body); color: var(--paper); }
  .search input::placeholder { color: var(--text3); }
  .list { overflow-y: auto; display: flex; flex-direction: column; gap: var(--space-2); min-height: 0; flex: 1; }
  .section { display: flex; align-items: center; gap: var(--space-6); margin: var(--space-8) 0 0; padding: var(--space-4) var(--space-12); font: var(--text-label); color: var(--text2); background: none; border: none; text-align: left; }
  .section .count { font: var(--text-detail); color: var(--text3); font-variant-numeric: tabular-nums; }
  .section.toggle:hover { color: var(--paper); background: none; }
  .rowwrap { position: relative; }
  .rowwrap > .row { width: 100%; }
  .menu { position: absolute; right: var(--space-8); top: var(--space-32); z-index: 20; min-width: 180px; display: flex; flex-direction: column; padding: var(--space-4); background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-card); box-shadow: var(--shadow-popover); }
  .menu button { text-align: left; background: transparent; border: 0; border-radius: var(--radius-chip); padding: var(--space-6) var(--space-8); font: var(--text-body); }
  .menu button:hover { background: var(--smoke); }
  .menu button.pick-time { display: inline-flex; align-items: center; gap: var(--space-6); color: var(--paper); }
  .dd-sep { height: 1px; background: var(--line2); margin: var(--space-4) var(--space-6); }
  .project { display: flex; align-items: center; gap: var(--space-6); width: 100%; background: transparent; border: 0; border-radius: var(--radius-chip); height: 32px; padding: 0 var(--space-12); font: var(--text-emphasis); color: var(--text-strong); text-align: left; margin-top: var(--space-8); }
  .project:hover { background: var(--row-hover); color: var(--paper); }
  .project.ask .pname { color: var(--paper); }
  .chev { width: 10px; color: var(--text3); }
  .pname { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .count { font: var(--text-detail); color: var(--text3); }
  /* The row (`AgentListRow`): no fill at rest, the row fill under the pointer and when open. */
  .row { display: flex; flex-direction: column; text-align: left; background: transparent; border: 0; border-radius: var(--radius-chip); padding: var(--space-8) calc(var(--space-8) + var(--space-2)); margin: 0; min-width: 0; }
  .row:hover { background: var(--row-hover); }
  .row.on { background: var(--row-selected); }
  .row.drop-target { background: color-mix(in srgb, var(--blue) 16%, transparent); outline: 1.5px solid var(--blue); outline-offset: -1.5px; }
  .row.slim { padding: var(--space-6) calc(var(--space-8) + var(--space-2)); }
  .line0 { display: flex; align-items: center; gap: var(--space-4); height: 20px; font: var(--text-detail); color: var(--text3); min-width: 0; }
  .sel-box { display: inline-flex; align-items: center; color: var(--text3); margin-right: var(--space-2); flex: none; }
  .sel-box.checked { color: var(--paper); }
  .badge-mark { display: inline-flex; padding-right: var(--space-2); }
  .folder { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .slot { display: inline-flex; align-items: center; flex: none; }
  .ago { font: var(--text-detail); color: var(--text3); white-space: nowrap; }
  /* `AgentStatusBadge`: the mark and the word in the status's color, no fill, 18 pt tall. */
  .status { display: inline-flex; align-items: center; gap: var(--space-4); height: 18px; padding: 0 var(--space-4); font: var(--text-label); white-space: nowrap; }
  .status .num { font-variant-numeric: tabular-nums; }
  .status.amber { color: var(--amber); }
  .status.coral { color: var(--coral); }
  .status.blue { color: var(--blue); }
  .status.mint { color: var(--mint); }
  .status.muted { color: var(--text3); }
  .pulse { width: 6px; height: 6px; margin: 0 var(--space-2); border-radius: 50%; background: currentColor; box-shadow: 0 0 0 3px color-mix(in srgb, currentColor 25%, transparent); }
  .line1 { display: flex; align-items: center; gap: var(--space-6); height: 20px; margin-top: var(--space-4); min-width: 0; }
  .compacting-line { margin-top: var(--space-2); font: var(--text-detail); color: var(--blue); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row.receded .title { font: var(--text-body); color: var(--text2); }
  .line2 { display: flex; align-items: center; gap: var(--space-6); height: 16px; margin-top: var(--space-2); font: var(--text-detail); color: var(--text3); min-width: 0; }
  .branch { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row.picked { background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .selection { display: flex; flex-direction: column; gap: var(--space-8); padding: calc(var(--space-8) + var(--space-2)); border: 1px solid var(--line2); border-radius: var(--radius-panel); background: var(--graphite); box-shadow: var(--shadow-popover); }
  .sel-head, .sel-actions { display: flex; align-items: center; gap: var(--space-4); flex-wrap: wrap; }
  .sel-head strong { font: var(--text-emphasis); color: var(--paper); }
  .sel-actions button { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-control); }
  .sel-actions .danger { color: var(--coral); }
  .ctx-backdrop { position: fixed; inset: 0; z-index: 49; }
  .menu.ctx { position: fixed; right: auto; z-index: 50; min-width: 220px; }
  .ctx-head { padding: var(--space-4) var(--space-8); font: var(--text-label); color: var(--text3); }
  .menu hr { border: 0; border-top: 1px solid var(--line2); margin: var(--space-4) 0; width: 100%; }
  .snooze-backdrop { position: fixed; inset: 0; z-index: 80; display: grid; place-items: center; padding: var(--space-24); background: color-mix(in srgb, var(--canvas) 55%, transparent); }
  .snooze-sheet { width: min(360px, 100%); padding: var(--space-16); background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-sheet); box-shadow: var(--shadow-popover); }
  .snooze-form { display: flex; flex-direction: column; gap: var(--space-12); }
  .snooze-head { display: flex; align-items: center; gap: var(--space-8); }
  .snooze-head h3 { margin: 0; font: var(--text-title); color: var(--paper); }
  .snooze-tabs { display: grid; grid-template-columns: 1fr 1fr; gap: var(--space-2); padding: var(--space-2); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--graphite); }
  .snooze-tabs button { height: 28px; border: 0; border-radius: var(--radius-chip); background: transparent; font: var(--text-control); color: var(--text2); }
  .snooze-tabs button.on { background: var(--smoke); color: var(--paper); }
  .snooze-row { display: flex; gap: var(--space-8); align-items: center; }
  .snooze-row input, .snooze-row select { flex: 1; min-width: 0; height: 34px; padding: 0 var(--space-12); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--graphite); color: var(--paper); font: var(--text-body); }
  .snooze-preview { margin: 0; font: var(--text-detail); color: var(--text2); }
  .snooze-preview.invalid { color: var(--coral); }
  .snooze-foot { display: flex; align-items: center; gap: var(--space-8); }
  .favicon { width: 18px; height: 18px; object-fit: contain; border-radius: calc(var(--radius-chip) * 0.75); }
  .badge-mark.dashed { width: 18px; justify-content: center; color: var(--text3); }
  .lines { display: inline-flex; gap: var(--space-4); font: var(--text-caption); font-family: var(--mono); font-weight: 400; white-space: nowrap; }
  .lines .plus { color: var(--added); }
  .lines .minus { color: var(--removed); }
  .lines.dim .plus, .lines.dim .minus { color: var(--text3); }
  .logo { display: inline-flex; padding-right: 3px; }
  .row.slim .title { color: var(--text2); }
  .snippet { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: block; height: auto; }
  /* The hover buttons sit level with the first line, over the status they replace. */
  .row-actions { position: absolute; top: var(--space-8); right: var(--space-8); display: flex; gap: var(--space-2); padding-left: var(--space-8); opacity: 0; pointer-events: none; background: var(--row-hover); transition: opacity var(--motion-hover); }
  .rowwrap:has(.row.on) .row-actions { background: var(--row-selected); }
  .rowwrap:hover .row-actions, .row-actions:focus-within { opacity: 1; pointer-events: auto; }
  .row-action { display: grid; place-items: center; width: 22px; height: 22px; padding: 0; margin: 0; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text2); }
  .row-action:hover, .row-action.lit { background: var(--graphite); color: var(--paper); }
  .empty { padding: var(--space-8); }
  .main { min-width: 0; min-height: 0; padding: 12px 16px; overflow: hidden; display: flex; flex-direction: column; }
  .main.thread { padding: 0; }
  /* A page brings its own header in the window's top row and its own side padding (`PageHeader`). */
  .main.page { padding: 0; }
  .main.thread > .err { padding: 8px 16px 0; }
  .err { color: var(--coral); font-size: 12px; margin: 0 0 6px; }
  @media (max-width: 800px) {
    .tab:not(.compact):not(.docked) { grid-template-columns: 210px minmax(0, 1fr); }
  }
  @media (max-width: 640px) {
    .tab:not(.compact) { grid-template-columns: minmax(0, 1fr); overflow-y: auto; display: flex; flex-direction: column; }
    .tab:not(.compact) aside { max-height: 36%; flex-shrink: 0; border-right: 0; border-bottom: 1px solid var(--border); }
    .tab:not(.compact) .main { flex: 1; min-height: 280px; overflow-y: auto; }
  }
</style>
