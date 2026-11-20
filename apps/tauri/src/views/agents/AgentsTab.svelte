<script lang="ts">
  import { loadAgentsView, onAgentsView, saveAgentsView, type AgentsView } from "../../lib/agents-view";
  // De tab Agents (`AgentsTab` en `AgentInboxList` op de Mac): links elke sessie, van welke agent ook, hier of in een
  // terminal gestart; rechts de gekozen sessie, of na de knop "Nieuwe sessie" de plek om er een te starten. Wat op jou
  // wacht staat bovenaan, daarna wat werkt, dan de rest; eerdere sessies wachten ingeklapt onderaan.
  import { agentNames, type AgentSession, type PastSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { ask } from "../../lib/confirm.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";
  import { isActive, isScratch, projectName, workspaceApi, type WorkspaceRun } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Browser from "../workspace/Browser.svelte";
  import Terminals from "../workspace/Terminals.svelte";
  import UsageModal from "./UsageModal.svelte";
  import EmptyState from "./EmptyState.svelte";
  import Worktrees from "../workspace/Worktrees.svelte";
  import LiveDetail from "./LiveDetail.svelte";
  import PastDetail from "./PastDetail.svelte";
  import Actions from "./actions/Actions.svelte";
  import PullRequests from "./pulls/PullRequests.svelte";
  import NewSession from "./run/NewSession.svelte";
  import RunPanel from "./run/RunPanel.svelte";
  import { ago, folderName } from "./time";
  import { openNewSessionIn } from "./new-session.svelte";
  import Ico from "../../components/ui/Ico.svelte";
  import Dropdown from "../../components/ui/Dropdown.svelte";
  import DropdownRow from "../../components/ui/DropdownRow.svelte";
  import ProjectIconView from "../../components/ui/ProjectIconView.svelte";
  import AgentMark from "../companion/ui/AgentMark.svelte";
  import { open as openDialog } from "@tauri-apps/plugin-dialog";
  import { revealItemInDir } from "@tauri-apps/plugin-opener";
  import { api } from "../../lib/api";
  import * as inbox from "../../lib/agent-inbox";
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
  let customSnooze = $state("");
  /// "2026-11-20T09:00" in local time, for the custom snooze field.
  function localMoment(ms: number): string {
    const d = new Date(ms);
    const p = (n: number) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
  }
  function update(next: InboxState) {
    inboxState = next;
    menuFor = null;
    try { localStorage.setItem(STATE_KEY, JSON.stringify(next)); } catch { /* No storage: the choice lasts until the window closes. */ }
  }
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
    agents.loadHistory();
    const timer = setInterval(() => {
      agents.loadHistory();
      now = Date.now();
    }, 30_000);
    return () => clearInterval(timer);
  });

  type Status = "waiting" | "input" | "failed" | "limited" | "working" | "idle" | "finished";
  interface Item {
    id: string;
    folder: string;
    title: string;
    branch: string | null;
    agent: string;
    status: Status;
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
      started: isActive(r.status) ? (r.turnStartedAt ?? r.createdAt) : r.updatedAt,
      path: r.workingDirectory,
      unseen: r.status === "completed" && unseen(key, r.updatedAt),
      added: r.linesAdded ?? 0,
      removed: r.linesRemoved ?? 0,
      scratch: isScratch(r.projectPath),
      root: r.repoRoot ?? r.projectPath,
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
      started: status === "idle" ? (s.updated ?? s.started) : s.started,
      path: s.cwd,
      unseen: s.status === "done" && unseen(s.id, s.updated),
      added: s.linesAdded,
      removed: s.linesRemoved,
      scratch: isScratch(s.cwd),
      root: s.cwd,
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
    switch (i.status) {
      case "waiting": return { word: tr("Goedkeuring", "Approval"), icon: "shield-half", tone: "amber" };
      case "input": return { word: tr("Antwoord", "Answer"), icon: "message-circle-question", tone: "amber" };
      case "failed": return { word: tr("Mislukt", "Failed"), icon: "circle-alert", tone: "coral" };
      case "limited": return { word: tr("Limiet", "Limit"), icon: "clock", tone: "amber" };
      case "working": return { word: tr("Bezig", "Working"), icon: null, tone: "blue", detail: i.started ? ago(i.started, now) : undefined };
      default: return i.unseen ? { word: tr("Klaar", "Ready"), icon: "circle-check", tone: "mint" } : null;
    }
  }

  /// "Add project" at the head of the list (`AddProjectButton`): a folder on disk becomes a favorite project and the
  /// new-session screen opens on it.
  async function addProject() {
    try {
      const picked = await openDialog({ directory: true, multiple: false, title: tr("Project toevoegen", "Add project") });
      if (typeof picked !== "string") return;
      // A favorite is a project of yours (the Mac pins what you add); read back before the last project is saved over it.
      if (!(workspace.settings?.favoriteProjects ?? []).includes(picked)) { await workspaceApi.toggleFavoriteProject(picked); await workspace.refresh(); }
      await openNewSessionIn(picked);
    } catch (e) {
      agents.error = String(e);
    }
  }

  /// The keys of the open session (`OpenSessionActions`, the Mac's `Keybindings` defaults with Ctrl for ⌘): Ctrl+Shift+S
  /// settles it, Ctrl+Shift+P pins it, F2 renames it, Ctrl+Shift+C copies where it works, and Ctrl+Shift+M / E / A open
  /// the composer's model picker (effort and access are in its footer).
  function keys(e: KeyboardEvent) {
    const typing = (e.target as HTMLElement | null)?.closest("input, textarea, [contenteditable]") !== null;
    const id = currentId;
    const row = byId.get(id);
    if (e.ctrlKey && e.shiftKey && !e.altKey) {
      const key = e.key.toLowerCase();
      if (key === "s" && row) {
        e.preventDefault();
        update(inboxState.settled.includes(id) ? inbox.unsettle(inboxState, id) : inbox.settle(inboxState, id));
      } else if (key === "p" && row) {
        e.preventDefault();
        update(inboxState.pinned.includes(id) ? inbox.unpin(inboxState, id) : inbox.pin(inboxState, id));
      } else if (key === "c" && row && !typing) {
        e.preventDefault();
        navigator.clipboard.writeText(row.path).catch(() => {});
      } else if (key === "m" || key === "e" || key === "a") {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("nook-agents-picker", { detail: key === "a" ? "access" : "model" }));
      }
    } else if (e.ctrlKey && !e.shiftKey && !e.altKey && e.key.toLowerCase() === "o" && row?.path) {
      // Ctrl+O (`session.openInEditor`): the session's folder in the editor chosen in Settings › Editor & browser.
      e.preventDefault();
      workspaceApi.openIn(row.path).catch((err) => (agents.error = String(err)));
    } else if (e.key === "F2" && !typing && id.startsWith("run:")) {
      e.preventDefault();
      window.dispatchEvent(new CustomEvent("nook-agents-rename", { detail: id }));
    }
  }

  // Several rows at once (`ListSelection`): Ctrl-click adds or removes a row, Shift-click takes the rows in between.
  let picked = $state(new Set<string>());
  let selecting = $state(false);
  let lastClicked: string | null = null;
  let projectMenu = $state<{ id: string; x: number; y: number } | null>(null);
  const shownIds = $derived([...list.flatMap((sec) => sec.rows.map((r) => r.row.id))]);

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

  // Archive and delete are for sessions Nook runs that are not working; deleting asks first, as the Mac does.
  const pickedRuns = $derived([...picked].filter((id) => id.startsWith("run:")).map((id) => workspace.run(id)).filter((r): r is WorkspaceRun => !!r && !isActive(r.status)));
  const archivable = $derived(pickedRuns.filter((r) => !r.archived));
  const deletable = $derived(pickedRuns.filter((r) => r.archived || inboxState.settled.includes(`run:${r.id}`)));

  async function archivePicked() {
    for (const r of archivable) await workspace.act(() => workspaceApi.archive(r.id, true));
    picked = new Set();
  }

  async function deletePicked() {
    const list = deletable;
    if (!(await ask({ question: tr("{n} afgehandelde of gearchiveerde sessies verwijderen?", "Delete {n} settled or archived sessions?", { n: list.length }), confirmTitle: tr("Verwijderen", "Delete") }))) return;
    for (const r of list) await workspace.act(() => workspaceApi.remove(r.id));
    picked = new Set();
  }

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
      <!-- The Mac's head of the session list: a quiet search (`NookSearchField`, ghost), then the view menu, add project
           and new session as header icons (`PanelHeaderIcon`), lit only while what they stand for is on. -->
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
        {/snippet}
      </Dropdown>
      <button class="head-icon" title={tr("Project toevoegen", "Add project")} aria-label={tr("Project toevoegen", "Add project")} onclick={addProject}><Ico name="folder-plus" size={16} /></button>
      <button class="head-icon" class:on={selected.kind === "new"} title={tr("Nieuwe sessie", "New session")} aria-label={tr("Nieuwe sessie", "New session")} onclick={() => agents.select("new")}><Ico name="square-pen" size={16} /></button>
    </div>
    <div class="list">
      {#snippet entryRow(entry: InboxEntry, kind: inbox.SectionKind)}
        {@const i = byId.get(entry.row.id)}
        {#if i}
          {@const badge = kind === "snoozed" || entry.woke ? null : badgeOf(i)}
          {@const meta = !!i.branch || i.added + i.removed > 0}
          <div class="rowwrap">
            <!-- A session row (`AgentListRow` in `AgentRowLayout`): the project's badge and name with the status or how long
                 ago; the session's name; its branch with the agent's logo at the end (beside the name when there is no branch). -->
            <button class="row" class:on={currentId === i.id} class:receded={entry.receded} class:picked={picked.has(i.id)}
              onclick={(e) => clickRow(e, i.id)} oncontextmenu={(e) => { if (!i.scratch && i.root) { e.preventDefault(); projectMenu = { id: i.id, x: e.clientX, y: e.clientY }; } }}>
              <span class="line0">
                {#if i.scratch}
                  <span class="badge-mark dashed"><Ico name="square-dashed" size={12} stroke={2.4} /></span>
                  <span class="folder" title={i.path}>{tr("Geen project", "No project")}</span>
                {:else}
                  <span class="badge-mark">{#if favicons[i.root]}<img class="favicon" src={favicons[i.root]} alt="" width="18" height="18" />{:else}<ProjectIconView name={i.folder} size={18} />{/if}</span>
                  <span class="folder" title={i.path}>{i.folder}</span>
                {/if}
                <span class="spacer"></span>
                <span class="slot">
                  {#if kind === "snoozed"}<span class="status muted"><Ico name="bell-off" size={11} stroke={2.5} />{tr("tot {time}", "until {time}", { time: new Date(inboxState.snoozed[i.id]).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }) })}</span>
                  {:else if entry.woke}<span class="status amber"><Ico name="alarm-clock" size={11} stroke={2.5} />{tr("Wakker", "Awake")}</span>
                  {:else if badge}<span class="status {badge.tone}">{#if badge.icon}<Ico name={badge.icon} size={11} stroke={2.5} />{:else}<span class="pulse"></span>{/if}{badge.word}{#if badge.detail}<span class="num">{badge.detail}</span>{/if}</span>
                  {:else}<span class="ago">{ago(i.started, now)}</span>{/if}
                </span>
              </span>
              <span class="line1"><span class="title">{i.title}</span>{#if !meta}<span class="spacer"></span><span class="logo"><AgentMark agent={i.agent} size={14} /></span>{/if}</span>
              {#if meta}
                <!-- The branch, then what the session changed ("+120 −8", `changeCount`), then the agent's logo. -->
                <span class="line2">{#if i.branch}<span class="branch">{i.branch}</span>{/if}<span class="spacer"></span>{#if i.added + i.removed > 0}<span class="lines" class:dim={i.status === "finished"}><span class="plus">+{i.added}</span><span class="minus">−{i.removed}</span></span>{/if}<span class="logo"><AgentMark agent={i.agent} size={14} /></span></span>
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
                <button role="menuitem" onclick={() => update(inbox.snooze(inboxState, i.id, now + 3_600_000))}>{tr("Snooze 1 uur", "Snooze 1 hour")}</button>
                <button role="menuitem" onclick={() => { const d = new Date(now); d.setDate(d.getDate() + 1); d.setHours(9, 0, 0, 0); update(inbox.snooze(inboxState, i.id, d.getTime())); }}>{tr("Snooze tot morgen", "Snooze until tomorrow")}</button>
                <!-- "Custom…" (`SnoozeMenuItems`): a moment of your own choosing. -->
                <form class="custom" onsubmit={(e) => { e.preventDefault(); const at = Date.parse(customSnooze); if (at > now) update(inbox.snooze(inboxState, i.id, at)); }}>
                  <input type="datetime-local" bind:value={customSnooze} min={localMoment(now)} aria-label={tr("Snooze tot", "Snooze until")} />
                  <button type="submit" disabled={!customSnooze || Date.parse(customSnooze) <= now}>{tr("Snooze", "Snooze")}</button>
                </form>
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
          <button class="project" class:ask={group.needsYou} aria-expanded={!folded} onclick={() => update(inbox.toggleProject(inboxState, group.project))}>
            <span class="chev">{folded ? "▸" : "▾"}</span><span class="pname">{group.project || tr("geen map", "no folder")}</span>
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
    {@const it = byId.get(projectMenu.id)}
    {#if it}
      <!-- The row's Project menu (`projectMenu`): what a project folder's menu does, from any of its sessions. -->
      <div class="ctx-backdrop" role="presentation" onclick={() => (projectMenu = null)} oncontextmenu={(e) => { e.preventDefault(); projectMenu = null; }}></div>
      <div class="menu ctx" role="menu" style:left="{projectMenu.x}px" style:top="{projectMenu.y}px">
        <div class="ctx-head">{tr("Project {name}", "Project {name}", { name: it.folder })}</div>
        <button role="menuitem" onclick={() => { projectMenu = null; openNewSessionIn(it.root); }}>{tr("Nieuwe sessie in {name}", "New session in {name}", { name: it.folder })}</button>
        <button role="menuitem" onclick={() => { projectMenu = null; workspaceApi.toggleFavoriteProject(it.root).then(() => workspace.refresh()); }}>{(workspace.settings?.favoriteProjects ?? []).includes(it.root) ? tr("Verwijder uit favorieten", "Remove from favorites") : tr("Voeg toe aan favorieten", "Add to favorites")}</button>
        <button role="menuitem" onclick={() => { projectMenu = null; revealItemInDir(it.root).catch(() => {}); }}>{tr("Toon in Verkenner", "Show in Explorer")}</button>
        <button role="menuitem" onclick={() => { projectMenu = null; navigator.clipboard.writeText(it.root).catch(() => {}); }}>{tr("Kopieer pad", "Copy path")}</button>
        <hr />
        <button role="menuitem" onclick={() => { projectMenu = null; selecting = true; picked = new Set([it.id]); }}>{tr("Selecteer…", "Select…")}</button>
      </div>
    {/if}
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
</div>

<style>
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
  .custom { display: flex; gap: var(--space-4); padding: var(--space-4); border-top: 1px solid var(--line2); margin-top: var(--space-4); }
  .custom input { flex: 1; min-width: 0; font: var(--text-detail); padding: var(--space-4) var(--space-6); }
  .custom button { flex: none; text-align: center; }
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
  .row.slim { padding: var(--space-6) calc(var(--space-8) + var(--space-2)); }
  .line0 { display: flex; align-items: center; gap: var(--space-4); height: 20px; font: var(--text-detail); color: var(--text3); min-width: 0; }
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
  .title { font: var(--text-emphasis); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row.receded .title { font: var(--text-body); color: var(--text2); }
  .line2 { display: flex; align-items: center; gap: var(--space-6); height: 16px; margin-top: var(--space-2); font: var(--text-detail); color: var(--text3); min-width: 0; }
  .branch { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .row.picked { background: color-mix(in srgb, var(--iris) 14%, transparent); }
  .selection { display: flex; flex-direction: column; gap: var(--space-8); padding: calc(var(--space-8) + var(--space-2)); border: 1px solid var(--line2); border-radius: var(--radius-panel); background: var(--graphite); }
  .sel-head, .sel-actions { display: flex; align-items: center; gap: var(--space-4); flex-wrap: wrap; }
  .sel-head strong { font: var(--text-emphasis); color: var(--paper); }
  .sel-actions button { display: inline-flex; align-items: center; gap: var(--space-4); font: var(--text-control); }
  .sel-actions .danger { color: var(--coral); }
  .ctx-backdrop { position: fixed; inset: 0; z-index: 49; }
  .menu.ctx { position: fixed; right: auto; z-index: 50; min-width: 220px; }
  .ctx-head { padding: var(--space-4) var(--space-8); font: var(--text-label); color: var(--text3); }
  .menu hr { border: 0; border-top: 1px solid var(--line2); margin: var(--space-4) 0; width: 100%; }
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
