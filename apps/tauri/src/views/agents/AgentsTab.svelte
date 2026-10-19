<script lang="ts">
  // De tab Agents (`AgentsTab` op de Mac): links elke sessie, van welke agent ook, hier of in een terminal gestart;
  // rechts de gekozen sessie, of na "+" de plek om er een te starten.
  import { agentNames, type AgentSession, type PastSession } from "../../lib/agents";
  import { agents } from "../../lib/agents.svelte";
  import LiveDetail from "./LiveDetail.svelte";
  import PastDetail from "./PastDetail.svelte";
  import { ago, folderName } from "./time";

  let { compact = false }: { compact?: boolean } = $props();
  let query = $state("");
  let showFinished = $state(false);

  $effect(() => {
    agents.start();
    agents.loadHistory();
    const timer = setInterval(() => agents.loadHistory(), 30_000);
    return () => clearInterval(timer);
  });

  // Een proces dat Nook alleen ziet, staat er als zijn gesprek te lezen is (net als op de Mac); koppelen gaat via
  // Instellingen › Agents.
  const kindOf: Record<string, string> = { "Claude Code": "claude", Codex: "codex", "Gemini CLI": "gemini", Antigravity: "antigravity" };
  const live = $derived(
    agents.sessions.filter((s) => s.status !== "detected" || (agents.history?.sessions ?? []).some((p) => p.agent === kindOf[s.name] && p.cwd === s.cwd)),
  );
  const liveConversations = $derived(new Set(live.map((s) => s.sessionId).filter(Boolean)));
  const past = $derived((agents.history?.sessions ?? []).filter((p) => !liveConversations.has(p.sessionId)).slice(0, 60));

  function matches(text: string): boolean {
    const q = query.trim().toLowerCase();
    return !q || text.toLowerCase().includes(q);
  }

  const needsYou = $derived(live.filter((s) => (s.status === "waiting" || s.approvalId || s.questionId || s.status === "failed") && matches(s.name + s.project + s.lastPrompt)));
  const active = $derived(live.filter((s) => !needsYou.includes(s) && s.status !== "done" && matches(s.name + s.project + s.lastPrompt)));
  const idle = $derived(live.filter((s) => s.status === "done" && !needsYou.includes(s) && matches(s.name + s.project + s.lastPrompt)));
  const earlier = $derived(past.filter((p) => matches(p.title + p.cwd + agentNames[p.agent])));

  const selected = $derived.by(() => {
    const id = agents.selectedId;
    if (id?.startsWith("past:")) {
      const key = id.slice(5);
      const p = past.find((s) => `${s.agent}:${s.sessionId}` === key);
      if (p) return { kind: "past" as const, past: p };
    }
    const s = live.find((x) => x.id === id) ?? needsYou[0] ?? active[0];
    if (s) return { kind: "live" as const, live: s };
    return { kind: "none" as const };
  });

  function rowDot(s: AgentSession): string {
    if (s.approvalId || s.questionId || s.status === "waiting") return "waiting";
    if (s.status === "running") return "working";
    if (s.status === "failed") return "error";
    if (s.status === "done") return "unread";
    return "";
  }
</script>

<div class="tab" class:compact>
  <aside>
    <div class="head">
      <strong>Agents</strong>
      <span class="spacer"></span>
    </div>
    <input class="search" placeholder="Zoek in sessies" bind:value={query} />
    <div class="list">
      {#snippet row(s: AgentSession)}
        <button class="row" class:on={selected.kind === "live" && selected.live.id === s.id} onclick={() => agents.select(s.id)}>
          <span class="dot {rowDot(s)}"></span>
          <span class="text">
            <span class="line1">{s.lastPrompt || s.summary || s.name}</span>
            <span class="line2 faint">{s.project} · {s.name}{#if s.updated} · {ago(s.updated)}{/if}</span>
          </span>
        </button>
      {/snippet}
      {#if needsYou.length}<div class="section">Wacht op jou</div>{#each needsYou as s (s.id)}{@render row(s)}{/each}{/if}
      {#if active.length}<div class="section">Bezig</div>{#each active as s (s.id)}{@render row(s)}{/each}{/if}
      {#if idle.length}<div class="section">Klaar</div>{#each idle as s (s.id)}{@render row(s)}{/each}{/if}
      {#if earlier.length}
        <button class="section toggle" onclick={() => (showFinished = !showFinished)}>Eerder ({earlier.length}) {showFinished ? "▾" : "▸"}</button>
        {#if showFinished}
          {#each earlier as p (p.agent + p.sessionId)}
            <button class="row" class:on={selected.kind === "past" && selected.past === p} onclick={() => agents.select(`past:${p.agent}:${p.sessionId}`)}>
              <span class="dot"></span>
              <span class="text">
                <span class="line1">{p.title || "Sessie zonder titel"}</span>
                <span class="line2 faint">{folderName(p.cwd)} · {agentNames[p.agent]} · {ago(p.ended)}</span>
              </span>
            </button>
          {/each}
        {/if}
      {/if}
      {#if !live.length && !earlier.length}
        <p class="faint empty">{agents.history ? "Er werkt nu geen agent." : "Even kijken…"}</p>
      {/if}
    </div>
  </aside>
  <section class="main">
    {#if selected.kind === "live"}
      {#key selected.live.id}<LiveDetail session={selected.live} />{/key}
    {:else if selected.kind === "past"}
      {#key selected.past.sessionId}<PastDetail session={selected.past as PastSession} />{/key}
    {:else}
      <div class="none">
        <p>Er werkt nu geen agent.</p>
        <p class="faint">Koppel Claude Code, Codex of een andere agent bij Instellingen › Agents, of start hier een sessie.</p>
      </div>
    {/if}
  </section>
</div>

<style>
  .tab { display: grid; grid-template-columns: 280px 1fr; height: 100%; min-height: 0; }
  .tab.compact { grid-template-columns: 240px 1fr; }
  aside { border-right: 1px solid var(--line); display: flex; flex-direction: column; min-height: 0; padding: 10px 8px; gap: 6px; }
  .head { display: flex; align-items: center; padding: 0 6px; gap: 6px; }
  .spacer { flex: 1; }
  .search { margin: 0 2px; }
  .list { overflow-y: auto; display: flex; flex-direction: column; gap: 1px; min-height: 0; }
  .section { font-size: 11px; color: var(--text3); text-transform: uppercase; letter-spacing: 0.04em; padding: 8px 8px 4px; background: none; border: none; text-align: left; }
  .section.toggle:hover { color: var(--paper); background: none; }
  .row { display: flex; gap: 8px; align-items: flex-start; text-align: left; background: none; border: none; border-radius: 9px; padding: 7px 8px; }
  .row:hover { background: var(--smoke); }
  .row.on { background: var(--smoke); }
  .row .dot { margin-top: 5px; background: var(--line2); }
  .row .dot.working { background: var(--paper); }
  .row .dot.waiting { background: var(--amber); }
  .row .dot.unread { background: var(--mint); }
  .row .dot.error { background: var(--coral); }
  .text { display: flex; flex-direction: column; min-width: 0; }
  .line1, .line2 { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .line2 { font-size: 11.5px; }
  .empty { padding: 8px; }
  .main { min-width: 0; min-height: 0; padding: 12px 16px; overflow: hidden; }
  .none { padding: 24px; text-align: center; }
</style>
