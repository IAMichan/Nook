<script lang="ts">
  // De tijdlijn van een sessie die Nook draait (de tijdlijn in `AgentRunPanel` met `TimelineBlocks` en `TimelineFind`):
  // afgeronde beurten vouwen tot "… gewerkt", tool-aanroepen achter elkaar tot één zin, één levende regel terwijl de
  // agent werkt, zoeken met Ctrl+F, en volgen van het einde tot je zelf wegscrolt.
  import { isActive, type RunEvent, type WorkspaceRun } from "../../../lib/workspace/api";
  import * as T from "../../../lib/workspace/timeline";
  import EventRow from "./EventRow.svelte";
  import PlanCard from "./PlanCard.svelte";

  let {
    run,
    events,
    asking = false,
    onrevert,
    onretry,
    onimplement,
    openFile,
  }: {
    run: WorkspaceRun;
    events: RunEvent[];
    asking?: boolean;
    onrevert?: (e: RunEvent) => void;
    onretry: () => void;
    onimplement: (plan: string) => void;
    openFile?: (path: string) => void;
  } = $props();

  let open = $state(new Set<string>());
  let expanded = $state(new Set<string>());
  let scroller = $state<HTMLDivElement>();
  let atEnd = $state(true);
  let follow = $state(true);
  let finding = $state(false);
  let query = $state("");
  let findIndex = $state<number | null>(null);
  let findInput = $state<HTMLInputElement>();
  let now = $state(Date.now());

  const shown = $derived(events.filter((e) => !(e.kind === "system" && e.tool === "launch")));
  const active = $derived(isActive(run.status));
  const list = $derived(T.blocks(shown, active));
  const found = $derived(finding ? T.search(shown, query) : ({ state: "idle", matches: [] } as T.SearchResult));
  const current = $derived(findIndex !== null && found.matches[findIndex] ? found.matches[findIndex].eventId : null);
  const liveLine = $derived(T.live(shown));
  const latestPlan = $derived([...shown].reverse().find((e) => e.kind === "assistant" && e.tool === "plan")?.id);

  $effect(() => {
    if (!active) return;
    const t = setInterval(() => (now = Date.now()), 1000);
    return () => clearInterval(t);
  });

  // Nieuwe events volgen het einde, tenzij je weggescrold bent.
  $effect(() => {
    void shown.length;
    void shown[shown.length - 1]?.text.length;
    if (follow) queueMicrotask(() => toEnd(false));
  });

  // Je stuurde iets: dat is het nieuwste en volgt weer.
  let lastUser = "";
  $effect(() => {
    const u = [...shown].reverse().find((e) => e.kind === "user")?.id ?? "";
    if (u && u !== lastUser) {
      if (lastUser) follow = true;
      lastUser = u;
    }
  });

  function toEnd(smooth: boolean) {
    scroller?.scrollTo({ top: scroller.scrollHeight, behavior: smooth ? "smooth" : "auto" });
  }

  function onscroll() {
    if (!scroller) return;
    atEnd = scroller.scrollTop + scroller.clientHeight >= scroller.scrollHeight - 48;
    if (atEnd) follow = true;
  }

  function onwheel() {
    if (!atEnd) follow = false;
    queueMicrotask(() => {
      if (!atEnd) follow = false;
    });
  }

  function toggleBlock(key: string) {
    const next = new Set(open);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    open = next;
  }

  function toggleEvent(id: string) {
    const next = new Set(expanded);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    expanded = next;
  }

  function reveal(id: string) {
    const keys = T.containers(list)[id] ?? [];
    if (keys.length) open = new Set([...open, ...keys]);
    follow = false;
    requestAnimationFrame(() => scroller?.querySelector(`[data-event="${id}"]`)?.scrollIntoView({ block: "center", behavior: "smooth" }));
  }

  function openFind() {
    finding = true;
    requestAnimationFrame(() => findInput?.focus());
  }

  function closeFind() {
    finding = false;
    query = "";
    findIndex = null;
  }

  function step(forward: boolean) {
    const target = forward ? T.nextMatch(found, findIndex) : T.previousMatch(found, findIndex);
    if (target === null) return;
    findIndex = target;
    reveal(found.matches[target].eventId);
  }

  function onquery() {
    findIndex = null;
    const fresh = T.search(shown, query);
    const first = T.nextMatch(fresh, null);
    if (first !== null) {
      findIndex = first;
      reveal(fresh.matches[first].eventId);
    }
  }

  function keydown(e: KeyboardEvent) {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f") {
      e.preventDefault();
      openFind();
    }
  }

  const failure = $derived(T.firstFailure(shown));
  const answered = (e: RunEvent) => shown.some((x) => x.kind === "user" && x.date > e.date);
</script>

<svelte:window onkeydown={keydown} />

<div class="wrap">
  {#if finding}
    <div class="find">
      <input bind:this={findInput} bind:value={query} oninput={onquery} placeholder="Zoek in sessie"
        onkeydown={(e) => { if (e.key === "Enter") step(!e.shiftKey); if (e.key === "Escape") closeFind(); }} />
      <span class="faint count">{found.state === "failed" ? "Te lang" : found.state === "noResults" ? "Niets gevonden" : T.countLabel(found, findIndex)}</span>
      <button class="ghost" title="Vorige" onclick={() => step(false)}>↑</button>
      <button class="ghost" title="Volgende" onclick={() => step(true)}>↓</button>
      <button class="ghost" title="Sluit" onclick={closeFind}>✕</button>
    </div>
  {/if}
  <div class="scroll" bind:this={scroller} {onscroll} {onwheel}>
    {#if !shown.length}<p class="faint small">Nog niets in dit gesprek. Stuur een bericht om verder te gaan.</p>{/if}

    {#snippet eventView(e: RunEvent)}
      <div data-event={e.id}>
        {#if e.kind === "assistant" && e.tool === "plan"}
          <PlanCard text={e.text} canAct={!active && latestPlan === e.id && !answered(e)} onimplement={() => onimplement(e.text)} />
        {:else}
          <EventRow event={e} expanded={expanded.has(e.id)} toggle={() => toggleEvent(e.id)} highlighted={current === e.id}
            {openFile} onrevert={e.kind === "user" && onrevert ? () => onrevert?.(e) : undefined} />
        {/if}
      </div>
    {/snippet}

    {#snippet blockView(b: T.TimelineBlock)}
      {#if b.type === "event"}
        {@render eventView(b.event)}
      {:else if b.type === "tools"}
        <div class="group">
          <button class="summary" class:fail={b.tally.failed} onclick={() => toggleBlock("group:" + b.id)}>
            <span class="sym">{b.tally.failed ? "⚠" : "⚒"}</span><span>{T.sentence(b.tally)}</span>
            <span class="chev" class:open={open.has("group:" + b.id)}>›</span>
          </button>
          {#if open.has("group:" + b.id)}
            <div class="inner">{#each b.events as e (e.id)}{@render eventView(e)}{/each}</div>
          {/if}
        </div>
      {:else}
        <div class="group">
          <button class="summary" onclick={() => toggleBlock("fold:" + b.id)}>
            <span class="sym">✓</span><span>{T.duration(b.seconds)} gewerkt</span>
            <span class="chev" class:open={open.has("fold:" + b.id)}>›</span>
          </button>
          {#if open.has("fold:" + b.id)}
            <div class="inner fold">{#each b.blocks as inner (inner.id)}{@render blockView(inner)}{/each}</div>
          {/if}
        </div>
      {/if}
    {/snippet}

    {#each list as b (b.id)}{@render blockView(b)}{/each}

    {#if active}
      {@const waiting = run.status === "waitingApproval" || asking}
      <div class="live">
        <span class="dot {waiting ? 'waiting' : 'working'}"></span>
        <div class="live-text">
          <div class="live-head">
            <span class="label">{waiting ? (asking ? "Wacht op je antwoord…" : "Wacht op je goedkeuring…") : (liveLine.tool ?? "De agent werkt…")}</span>
            {#if run.turnStartedAt && !waiting}<span class="faint mono">{T.duration((now - Date.parse(run.turnStartedAt)) / 1000)}</span>{/if}
          </div>
          {#if liveLine.thought && !waiting}<div class="thought">{liveLine.thought}</div>{/if}
        </div>
      </div>
    {/if}

    {#if run.status === "failed" || run.status === "stopped"}
      <div class="recovery {run.status}">
        <span>{run.status === "failed" ? "⚠" : "⏸"}</span>
        <div class="rtext">
          <strong>{run.status === "failed" ? "Deze beurt is mislukt." : run.statusDetail === "interrupted" ? "Nook stopte terwijl de agent werkte; het proces draait niet meer." : "Je hebt deze beurt gestopt."}</strong>
          <span class="faint">
            {run.statusDetail && run.statusDetail !== "interrupted"
              ? run.statusDetail
              : run.providerSessionId
                ? "Stuur een bericht of klik op Opnieuw: de agent gaat verder met dezelfde geschiedenis."
                : "De agent meldde nog geen sessie; Opnieuw start de opdracht vanaf het begin."}
          </span>
        </div>
        {#if failure}<button class="ghost" onclick={() => reveal(failure)}>Ga naar fout</button>{/if}
        <button onclick={onretry}>Opnieuw</button>
      </div>
    {/if}
  </div>
  {#if !follow && !atEnd && !finding}
    <button class="to-end" onclick={() => { follow = true; toEnd(true); }}>Naar einde ↓</button>
  {/if}
</div>

<style>
  .wrap { position: relative; flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; display: flex; flex-direction: column; gap: 12px; padding: 4px 2px 8px; }
  .find { display: flex; gap: 6px; align-items: center; padding: 4px; background: var(--graphite); border: 1px solid var(--line2); border-radius: 10px; margin-bottom: 6px; }
  .find input { flex: 1; padding: 4px 8px; }
  .count { font-size: 11.5px; min-width: 70px; text-align: right; }
  .group { display: flex; flex-direction: column; gap: 8px; }
  .summary { display: flex; gap: 7px; align-items: center; background: none; border: none; padding: 0; font-size: 12.5px; color: var(--text2); text-align: left; }
  .summary:hover { background: none; color: var(--paper); }
  .summary.fail { color: var(--coral); }
  .summary .sym { width: 14px; text-align: center; font-size: 11px; }
  .chev { display: inline-block; transition: transform 0.15s; opacity: 0.6; }
  .chev.open { transform: rotate(90deg); opacity: 0.9; }
  .inner { display: flex; flex-direction: column; gap: 8px; padding-left: 14px; }
  .inner.fold { border-left: 1px solid var(--line2); gap: 12px; }
  .live { display: flex; gap: 8px; align-items: flex-start; font-size: 12.5px; }
  .live .dot { margin-top: 5px; }
  .live-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .live-head { display: flex; gap: 6px; align-items: center; }
  .live-head .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text2); }
  .mono { font-family: var(--mono); font-size: 11px; }
  .thought { color: var(--text3); font-size: 12px; background: linear-gradient(90deg, var(--text3), var(--paper), var(--text3)); background-size: 200% 100%; -webkit-background-clip: text; background-clip: text; color: transparent; animation: shimmer 2.4s linear infinite; }
  @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -200% 0; } }
  .recovery { display: flex; gap: 10px; align-items: center; padding: 10px; border-radius: 9px; background: rgba(255, 184, 77, 0.07); }
  .recovery.failed { background: rgba(255, 107, 107, 0.07); }
  .rtext { flex: 1; display: flex; flex-direction: column; gap: 2px; font-size: 12px; }
  .to-end { position: absolute; bottom: 8px; left: 50%; transform: translateX(-50%); border-radius: 999px; font-size: 12px; padding: 4px 12px; }
  .small { font-size: 12.5px; }
</style>
