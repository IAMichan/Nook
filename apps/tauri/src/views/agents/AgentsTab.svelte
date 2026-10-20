<script lang="ts">
  // De tab Agents (`AgentsTab` en `AgentInboxList` op de Mac): links elke sessie, van welke agent ook, hier of in een
  // terminal gestart; rechts de gekozen sessie, of na de knop "Nieuwe sessie" de plek om er een te starten. Wat op jou
  // wacht staat bovenaan, daarna wat werkt, dan de rest; eerdere sessies wachten ingeklapt onderaan.
  import { agentNames, type AgentSession, type PastSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import { isActive, projectName, workspaceApi, type WorkspaceRun } from "../../lib/workspace/api";
  import { workspace } from "../../lib/workspace/store.svelte";
  import Browser from "../workspace/Browser.svelte";
  import Terminals from "../workspace/Terminals.svelte";
  import UsagePage from "../workspace/UsagePage.svelte";
  import Worktrees from "../workspace/Worktrees.svelte";
  import LiveDetail from "./LiveDetail.svelte";
  import PastDetail from "./PastDetail.svelte";
  import PullGlyph from "./pulls/PullGlyph.svelte";
  import PullRequests from "./pulls/PullRequests.svelte";
  import NewSession from "./run/NewSession.svelte";
  import RunPanel from "./run/RunPanel.svelte";
  import { ago, folderName } from "./time";

  let { compact = false }: { compact?: boolean } = $props();
  let query = $state("");
  let showFinished = $state(false);
  let now = $state(Date.now());

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

  const rank: Record<Status, number> = { waiting: 0, input: 1, failed: 2, limited: 3, working: 4, idle: 5, finished: 6 };
  function matches(i: Item): boolean {
    const q = query.trim().toLowerCase();
    return !q || `${i.title} ${i.folder} ${i.agent} ${i.branch ?? ""}`.toLowerCase().includes(q);
  }
  const items = $derived(
    [...runs.map(runItem), ...live.map(liveItem)]
      .map((item, index) => ({ item, index }))
      .sort((a, b) => rank[a.item.status] - rank[b.item.status] || a.index - b.index)
      .map((x) => x.item)
      .filter(matches),
  );
  const earlier = $derived(past.filter((p) => !query.trim() || `${p.title} ${p.cwd} ${agentNames[p.agent]}`.toLowerCase().includes(query.trim().toLowerCase())));

  const pages = ["pulls", "usage", "terminals", "browser", "worktrees"] as const;
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
    if (endTerminal && !confirm(`${s.name} in ${s.project} beëindigen en hier verdergaan? De agent bewaart zijn gesprek, zodat Nook verdergaat waar hij was.`)) return;
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

  const statusText: Record<Status, string> = {
    waiting: "wacht op jou", input: "vraagt iets", failed: "mislukt", limited: "limiet", working: "", idle: "", finished: "",
  };
  const dotClass: Record<Status, string> = {
    waiting: "waiting", input: "waiting", failed: "error", limited: "waiting", working: "working", idle: "", finished: "",
  };
</script>

<div class="tab" class:compact>
  <aside>
    <div class="head">
      <strong>Agents</strong>
      <span class="spacer"></span>
      <button class="new" class:on={selected.kind === "new"} title="Nieuwe sessie" aria-label="Nieuwe sessie" onclick={() => agents.select("new")}>✎</button>
    </div>
    <input class="search" placeholder="Zoek in sessies" bind:value={query} />
    <div class="list">
      {#each items as i (i.id)}
        <button class="row" class:on={currentId === i.id} class:receded={i.status === "idle" || i.status === "finished"} onclick={() => agents.select(i.id)}>
          <span class="line0">
            <span class="folder" title={i.path}>{i.folder}</span>
            <span class="spacer"></span>
            {#if statusText[i.status]}<span class="badge {i.status}">{statusText[i.status]}</span>
            {:else if i.unseen}<span class="badge done">klaar</span>
            {:else}<span class="faint">{ago(i.started, now)}</span>{/if}
          </span>
          <span class="line1">{#if dotClass[i.status]}<span class="dot {dotClass[i.status]}"></span>{/if}{i.title}</span>
          <span class="line2 faint">⑂ {i.branch ?? "geen branch"}<span class="spacer"></span>{i.agent}</span>
        </button>
      {/each}
      {#if earlier.length}
        <button class="section toggle" onclick={() => (showFinished = !showFinished)}>Afgerond ({earlier.length}) {showFinished ? "▾" : "▸"}</button>
        {#if showFinished}
          {#each earlier as p (p.agent + p.sessionId)}
            <button class="row slim" class:on={currentId === `past:${p.agent}:${p.sessionId}`} onclick={() => agents.select(`past:${p.agent}:${p.sessionId}`)}>
              <span class="line1">{p.title || "Sessie zonder titel"}</span>
              <span class="line2 faint">{folderName(p.cwd)} · {agentNames[p.agent]} · {ago(p.ended, now)}</span>
            </button>
          {/each}
        {/if}
      {/if}
      {#if !items.length && !earlier.length}
        <p class="faint empty">{agents.history ? "Er werkt nu geen agent." : "Even kijken…"}</p>
      {/if}
    </div>
    <div class="footer">
      <button class="glyph" class:on={selected.kind === "page" && selected.page === "pulls"} title="Pull requests" aria-label="Pull requests" onclick={() => agents.select("pulls")}><PullGlyph size={13} /></button>
      <button class:on={selected.kind === "page" && selected.page === "usage"} title="Gebruik" onclick={() => agents.select("usage")}>Gebruik</button>
      <span class="vsep"></span>
      <button class:on={selected.kind === "page" && selected.page === "terminals"} title="Alle terminals" onclick={() => agents.select("terminals")}>›_</button>
      <button class:on={selected.kind === "page" && selected.page === "browser"} title="Browser" onclick={() => agents.select("browser")}>◍</button>
      <button class:on={selected.kind === "page" && selected.page === "worktrees"} title="Worktrees" onclick={() => agents.select("worktrees")}>⑂</button>
    </div>
  </aside>
  <section class="main">
    {#if agents.error}<p class="err">{agents.error} <button class="ghost" onclick={() => (agents.error = null)}>✕</button></p>{/if}
    {#if selected.kind === "run"}
      {#key selected.id}<RunPanel runId={selected.id} ongone={() => agents.select(null)} />{/key}
    {:else if selected.kind === "live"}
      {#key selected.live.id}<LiveDetail session={selected.live} ontakeover={takeover} />{/key}
    {:else if selected.kind === "past"}
      {#key selected.past.sessionId}<PastDetail session={selected.past as PastSession} oncontinue={continuePast} />{/key}
    {:else if selected.kind === "page"}
      {#if selected.page === "pulls"}<PullRequests />
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
  .tab { display: grid; grid-template-columns: 280px 1fr; height: 100%; min-height: 0; }
  .tab.compact { grid-template-columns: 250px 1fr; }
  aside { border-right: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; padding: 10px 8px; gap: 6px; }
  .head { display: flex; align-items: center; padding: 0 6px; gap: 6px; }
  .spacer { flex: 1; }
  .new { background: none; border: none; width: 28px; height: 28px; padding: 0; border-radius: 8px; color: var(--text2); }
  .new.on, .new:hover { background: var(--smoke); color: var(--paper); }
  .search { margin: 0 2px; }
  .list { overflow-y: auto; display: flex; flex-direction: column; gap: 2px; min-height: 0; flex: 1; }
  .section { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 8px 8px 4px; background: none; border: none; text-align: left; }
  .section.toggle:hover { color: var(--paper); background: none; }
  .row { display: flex; flex-direction: column; gap: 3px; text-align: left; background: #09090a; border: none; border-radius: 12px; padding: 9px 12px; }
  .row:hover { background: #111113; }
  .row.on { background: #17171a; }
  .row.slim { padding: 7px 12px; }
  .line0, .line2 { display: flex; gap: 6px; font-size: 12px; color: var(--text2); align-items: center; }
  .line2 { color: var(--text3); }
  .row.receded .line0 { color: var(--text3); }
  .folder { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .line1 { font-size: 14px; font-weight: 500; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; display: flex; gap: 6px; align-items: center; }
  .row.receded .line1 { font-weight: 400; color: var(--text2); }
  .row.slim .line1 { font-size: 13px; color: var(--text2); }
  .badge { font-size: 11px; font-weight: 600; }
  .badge.waiting, .badge.input, .badge.limited { color: var(--amber); }
  .badge.failed { color: var(--coral); }
  .badge.done { color: var(--mint); }
  .empty { padding: 8px; }
  .footer { display: flex; gap: 4px; align-items: center; padding-top: 4px; }
  .footer button { background: none; border: none; height: 30px; padding: 0 9px; border-radius: 8px; color: var(--text3); font-size: 12px; }
  .footer button:hover, .footer button.on { color: var(--paper); background: #17171a; }
  .footer button.glyph { display: grid; place-items: center; }
  .vsep { width: 1px; height: 16px; background: var(--line2); margin: 0 4px; }
  .main { min-width: 0; min-height: 0; padding: 12px 16px; overflow: hidden; display: flex; flex-direction: column; }
  .err { color: var(--coral); font-size: 12px; margin: 0 0 6px; }
</style>
