<script lang="ts">
  // De tab Agents (`AgentsTab` en `AgentInboxList` op de Mac): links elke sessie, van welke agent ook, hier of in een
  // terminal gestart; rechts de gekozen sessie, of na de knop "Nieuwe sessie" de plek om er een te starten. Wat op jou
  // wacht staat bovenaan, daarna wat werkt, dan de rest; eerdere sessies wachten ingeklapt onderaan.
  import { agentNames, type AgentSession, type PastSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { tr, locale } from "../../lib/i18n.svelte";
  import { isActive, projectName, workspaceApi, type WorkspaceRun } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Browser from "../workspace/Browser.svelte";
  import Terminals from "../workspace/Terminals.svelte";
  import UsagePage from "../workspace/UsagePage.svelte";
  import Worktrees from "../workspace/Worktrees.svelte";
  import LiveDetail from "./LiveDetail.svelte";
  import PastDetail from "./PastDetail.svelte";
  import Actions from "./actions/Actions.svelte";
  import ActionsGlyph from "./actions/ActionsGlyph.svelte";
  import PullGlyph from "./pulls/PullGlyph.svelte";
  import PullRequests from "./pulls/PullRequests.svelte";
  import NewSession from "./run/NewSession.svelte";
  import RunPanel from "./run/RunPanel.svelte";
  import { ago, folderName } from "./time";
  import * as inbox from "../../lib/agent-inbox";
  import { emptyState, needsYou, type Attention, type InboxEntry, type InboxState } from "../../lib/agent-inbox";

  let { compact = false }: { compact?: boolean } = $props();
  let query = $state("");
  let showFinished = $state(false);
  // What you decided about the list (pins, settled, snoozed, folded projects) is remembered.
  const STATE_KEY = "nook.agents.inbox";
  function loadState(): InboxState {
    try { return { ...emptyState(), ...JSON.parse(localStorage.getItem(STATE_KEY) ?? "{}") }; } catch { return emptyState(); }
  }
  let inboxState = $state<InboxState>(loadState());
  let settledLimit = $state(inbox.settledPage);
  let menuFor = $state<string | null>(null);
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
      folder: projectName(r.projectPath),
      title: r.title,
      branch: r.branch,
      agent: workspace.provider(r.provider)?.name ?? r.provider,
      status,
      started: isActive(r.status) ? (r.turnStartedAt ?? r.createdAt) : r.updatedAt,
      path: r.workingDirectory,
      unseen: r.status === "completed" && unseen(key, r.updatedAt),
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
    };
  }

  const attentionOf: Record<Status, Attention> = {
    waiting: "approval", input: "input", failed: "failed", limited: "limited", working: "working", idle: "idle", finished: "finished",
  };
  const all = $derived([...runs.map(runItem), ...live.map(liveItem)]);
  const byId = $derived(new Map(all.map((i) => [i.id, i])));
  const rows = $derived(inbox.filterRows(
    all.map((i): inbox.InboxRow => ({
      id: i.id, title: i.title, project: i.folder, attention: i.unseen && i.status === "idle" ? "ready" : attentionOf[i.status],
      lastActivity: Date.parse(i.started ?? "") || 0, unread: i.unseen,
    })),
    query,
  ));
  const list = $derived(inbox.sections(rows, inboxState, { showWorking: !inboxState.groupByProject, now, settledLimit, selectedId: agents.selectedId }));
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
  const selected = $derived.by(() => {
    const id = agents.selectedId;
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
    if (endTerminal && !confirm(tr("{name} in {project} beëindigen en hier verdergaan? De agent bewaart zijn gesprek, zodat Nook verdergaat waar hij was.", "End {name} in {project} and continue here? The agent keeps its conversation, so Nook picks up where it left off.", { name: s.name, project: s.project }))) return;
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

  const statusText = $derived<Record<Status, string>>({
    waiting: tr("wacht op jou", "waiting for you"), input: tr("vraagt iets", "has a question"), failed: tr("mislukt", "failed"), limited: tr("limiet", "limit"), working: "", idle: "", finished: "",
  });
  const dotClass: Record<Status, string> = {
    waiting: "waiting", input: "waiting", failed: "error", limited: "waiting", working: "working", idle: "", finished: "",
  };
</script>

<div class="tab" class:compact class:docked>
  <aside use:dock class:docked>
    <div class="head">
      <input class="search" placeholder={tr("Zoek in sessies", "Search sessions")} bind:value={query} />
      <button class="new" class:on={inboxState.groupByProject} title={tr("Groepeer per project", "Group by project")} aria-label={tr("Groepeer per project", "Group by project")} onclick={() => update({ ...inboxState, groupByProject: !inboxState.groupByProject })}>▤</button>
      <button class="new" class:on={selected.kind === "new"} title={tr("Nieuwe sessie", "New session")} aria-label={tr("Nieuwe sessie", "New session")} onclick={() => agents.select("new")}>✎</button>
    </div>
    <div class="list">
      {#snippet entryRow(entry: InboxEntry, kind: inbox.SectionKind)}
        {@const i = byId.get(entry.row.id)}
        {#if i}
          <div class="rowwrap">
            <button class="row" class:on={currentId === i.id} class:receded={entry.receded} onclick={() => agents.select(i.id)}>
              <span class="line0">
                <span class="folder" title={i.path}>{i.folder}</span>
                <span class="spacer"></span>
                {#if kind === "snoozed"}<span class="faint">{tr("tot {time}", "until {time}", { time: new Date(inboxState.snoozed[i.id]).toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }) })}</span>
                {:else if entry.woke}<span class="badge done">{tr("wakker", "awake")}</span>
                {:else if statusText[i.status]}<span class="badge {i.status}">{statusText[i.status]}</span>
                {:else if i.unseen}<span class="badge done">{tr("klaar", "done")}</span>
                {:else}<span class="faint">{ago(i.started, now)}</span>{/if}
              </span>
              <span class="line1">{#if dotClass[i.status]}<span class="dot {dotClass[i.status]}"></span>{/if}{i.title}</span>
              <span class="line2 faint">⑂ {i.branch ?? tr("geen branch", "no branch")}<span class="spacer"></span>{i.agent}</span>
            </button>
            <button class="more" aria-label={tr("Acties voor sessie", "Session actions")} title={tr("Acties", "Actions")} onclick={(e) => { e.stopPropagation(); menuFor = menuFor === i.id ? null : i.id; }}>⋯</button>
            {#if menuFor === i.id}
              <div class="menu" role="menu">
                {#if inboxState.pinned.includes(i.id)}
                  <button role="menuitem" onclick={() => update(inbox.unpin(inboxState, i.id))}>{tr("Los maken", "Unpin")}</button>
                {:else}
                  <button role="menuitem" onclick={() => update(inbox.pin(inboxState, i.id))}>{tr("Vastzetten", "Pin")}</button>
                {/if}
                {#if inboxState.settled.includes(i.id)}
                  <button role="menuitem" onclick={() => update(inbox.unsettle(inboxState, i.id))}>{tr("Heropenen", "Reopen")}</button>
                {:else}
                  <button role="menuitem" onclick={() => update(inbox.settle(inboxState, i.id))}>{tr("Afronden", "Mark as done")}</button>
                {/if}
                {#if kind === "snoozed"}
                  <button role="menuitem" onclick={() => update(inbox.wake(inboxState, i.id))}>{tr("Wakker maken", "Wake up")}</button>
                {:else if !needsYou(entry.row.attention)}
                  <button role="menuitem" onclick={() => update(inbox.snooze(inboxState, i.id, now + 3_600_000))}>{tr("Snooze 1 uur", "Snooze 1 hour")}</button>
                  <button role="menuitem" onclick={() => { const d = new Date(now); d.setDate(d.getDate() + 1); d.setHours(9, 0, 0, 0); update(inbox.snooze(inboxState, i.id, d.getTime())); }}>{tr("Snooze tot morgen", "Snooze until tomorrow")}</button>
                {/if}
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
        <p class="section">{shelfTitle[shelf.kind]} ({shelf.rows.length + shelf.hiddenCount})</p>
        {#each shelf.rows as entry (entry.row.id)}{@render entryRow(entry, shelf.kind)}{/each}
        {#if shelf.hiddenCount > 0}
          <button class="section toggle" onclick={() => (settledLimit += inbox.settledPage)}>{tr("Toon {n} meer", "Show {n} more", { n: Math.min(inbox.settledPage, shelf.hiddenCount) })}</button>
        {/if}
      {/each}
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
        <p class="faint empty">{agents.history ? tr("Er werkt nu geen agent.", "No agent is working right now.") : tr("Even kijken…", "Just a moment…")}</p>
      {/if}
    </div>
    <div class="footer">
      <button class="glyph" class:on={selected.kind === "page" && selected.page === "pulls"} title="Pull requests" aria-label="Pull requests" onclick={() => agents.select("pulls")}><PullGlyph size={13} /></button>
      <button class="glyph" class:on={selected.kind === "page" && selected.page === "actions"} title="Actions" aria-label="Actions" onclick={() => agents.select("actions")}><ActionsGlyph size={13} /></button>
      <button class:on={selected.kind === "page" && selected.page === "usage"} title={tr("Gebruik", "Usage")} onclick={() => agents.select("usage")}>{tr("Gebruik", "Usage")}</button>
      <span class="vsep"></span>
      <button class:on={selected.kind === "page" && selected.page === "terminals"} title={tr("Alle terminals", "All terminals")} onclick={() => agents.select("terminals")}>›_</button>
      <button class:on={selected.kind === "page" && selected.page === "browser"} title="Browser" onclick={() => agents.select("browser")}>◍</button>
      <button class:on={selected.kind === "page" && selected.page === "worktrees"} title="Worktrees" onclick={() => agents.select("worktrees")}>⑂</button>
    </div>
  </aside>
  <section class="main" class:thread={selected.kind === "run" || selected.kind === "live" || selected.kind === "past"}>
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
      {:else if selected.page === "usage"}<UsagePage />
      {:else if selected.page === "terminals"}<Terminals />
      {:else if selected.page === "browser"}<Browser />
      {:else}<Worktrees />{/if}
    {:else}
      <NewSession onstarted={(id) => agents.select(`run:${id}`)} />
    {/if}
  </section>
</div>

<style>
  .tab { display: grid; grid-template-columns: 260px minmax(0, 1fr); height: 100%; min-height: 0; }
  .tab.compact { grid-template-columns: 250px 1fr; }
  .tab.docked { grid-template-columns: minmax(0, 1fr); }
  aside { border-right: 1px solid var(--border); display: flex; flex-direction: column; min-height: 0; padding: 10px 8px; gap: 6px; }
  /* Docked in the sidebar: no column of its own, the sidebar's edge and padding are the list's. */
  aside.docked { border-right: 0; padding: 0; flex: 1; min-height: 0; }
  .head { display: flex; align-items: center; padding: 0 2px; gap: 4px; }
  .spacer { flex: 1; }
  .new { background: none; border: none; width: 28px; height: 28px; padding: 0; flex: none; border-radius: var(--radius-control); color: var(--text2); }
  .new.on { background: var(--row-selected); color: var(--paper); }
  .new:hover { background: var(--row-hover); color: var(--paper); }
  .search { flex: 1; min-width: 0; height: 28px; padding: 0 10px; font-size: 12px; background: var(--surface); }
  .list { overflow-y: auto; display: flex; flex-direction: column; gap: 1px; min-height: 0; flex: 1; }
  .section { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 8px 8px 4px; background: none; border: none; text-align: left; }
  .section.toggle:hover { color: var(--paper); background: none; }
  .rowwrap { position: relative; }
  .rowwrap > .row { width: 100%; }
  .more { position: absolute; right: 4px; bottom: 4px; width: 22px; height: 20px; padding: 0; background: transparent; border: 0; border-radius: var(--radius-chip); color: var(--text3); opacity: 0; line-height: 1; }
  .rowwrap:hover .more, .more:focus-visible { opacity: 1; }
  .more:hover { background: var(--smoke); color: var(--paper); }
  .menu { position: absolute; right: 4px; top: 100%; z-index: 20; min-width: 160px; display: flex; flex-direction: column; padding: 4px; background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); }
  .menu button { text-align: left; background: transparent; border: 0; border-radius: var(--radius-chip); padding: 6px 8px; font-size: 12.5px; }
  .menu button:hover { background: var(--row-hover); }
  .project { display: flex; align-items: center; gap: 6px; width: 100%; background: transparent; border: 0; border-radius: var(--radius-control); padding: 6px 10px; font-size: 12px; font-weight: 600; color: var(--text2); text-align: left; margin-top: 6px; }
  .project:hover { background: var(--row-hover); color: var(--paper); }
  .project.ask .pname { color: var(--paper); }
  .chev { width: 10px; font-size: 9px; color: var(--text3); }
  .pname { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .count { font-size: 11px; font-weight: 500; }
  .row { display: flex; flex-direction: column; gap: 2px; text-align: left; background: transparent; border: 0; border-radius: var(--radius-control); padding: 8px 10px; }
  .row:hover { background: var(--row-hover); }
  .row.on { background: var(--row-selected); }
  .row.slim { padding: 6px 10px; }
  .line0, .line2 { display: flex; gap: 6px; font-size: 11.5px; color: var(--text2); align-items: center; }
  .line2 { color: var(--text3); font-size: 10.5px; }
  .row.receded .line0 { color: var(--text3); }
  .folder { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .line1 { font-size: 13px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; gap: 6px; align-items: center; }
  .row.receded .line1 { font-weight: 400; color: var(--text2); }
  .row.slim .line1 { font-size: 12.5px; color: var(--text2); }
  .badge { font-size: 11px; font-weight: 600; }
  .badge.waiting, .badge.input, .badge.limited { color: var(--amber); }
  .badge.failed { color: var(--coral); }
  .badge.done { color: var(--mint); }
  .empty { padding: 8px; }
  .footer { display: flex; gap: 2px; align-items: center; padding-top: 4px; }
  .footer button { background: none; border: none; height: 28px; padding: 0 8px; border-radius: var(--radius-control); color: var(--text3); font-size: 12px; }
  .footer button:hover { color: var(--paper); background: var(--row-hover); }
  .footer button.on { color: var(--paper); background: var(--row-selected); }
  .footer button.glyph { display: grid; place-items: center; }
  .vsep { width: 1px; height: 14px; background: var(--line2); margin: 0 4px; }
  .main { min-width: 0; min-height: 0; padding: 12px 16px; overflow: hidden; display: flex; flex-direction: column; }
  .main.thread { padding: 0; }
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
