<script lang="ts">
  // De tijdlijn van een sessie die Nook draait (de tijdlijn in `AgentRunPanel` met `TimelineBlocks` en `TimelineFind`):
  // afgeronde beurten vouwen tot "… gewerkt", tool-aanroepen achter elkaar tot één zin, één levende regel terwijl de
  // agent werkt, zoeken met Ctrl+F, en volgen van het einde tot je zelf wegscrolt.
  import { isActive, workspaceApi, type RunEvent, type WorkspaceRun } from "../../../lib/workspace/api";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import * as T from "../../../lib/workspace/timeline";
  import { tr, locale } from "../../../lib/i18n.svelte";
  import Icon from "../../../components/Icon.svelte";
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

  // Een gebruikslimiet beëindigde de beurt: een eigen kaart op de plek van "Je hebt deze beurt gestopt".
  const limited = $derived(!!run.limitedAt && !active);
  $effect(() => {
    if (!limited) return;
    now = Date.now();
    const t = setInterval(() => (now = Date.now()), 30_000);
    return () => clearInterval(t);
  });

  function limitLine(): string {
    if (!run.limitResetAt) return tr("Wanneer de limiet vrijkomt is onbekend; probeer het later zelf opnieuw.", "It's unknown when the limit resets; try again yourself later.");
    const reset = Date.parse(run.limitResetAt);
    if (reset <= now) return run.autoResume ? tr("De limiet is vrij; de sessie gaat zo verder.", "The limit has reset; the session continues shortly.") : tr("De limiet is weer vrij. Stuur een bericht om verder te gaan.", "The limit has reset. Send a message to continue.");
    const d = new Date(reset);
    const today = d.toDateString() === new Date(now).toDateString();
    const clock = today ? d.toLocaleTimeString(locale(), { hour: "2-digit", minute: "2-digit" }) : d.toLocaleString(locale(), { day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" });
    const wait = T.duration((reset - now) / 1000);
    return run.autoResume ? tr("Gaat verder om {time} (over {wait})", "Continues at {time} (in {wait})", { time: clock, wait }) : tr("Vrij om {time} (over {wait})", "Resets at {time} (in {wait})", { time: clock, wait });
  }

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
      <input bind:this={findInput} bind:value={query} oninput={onquery} placeholder={tr("Zoek in sessie", "Search session")}
        onkeydown={(e) => { if (e.key === "Enter") step(!e.shiftKey); if (e.key === "Escape") closeFind(); }} />
      <span class="faint count">{found.state === "failed" ? tr("Te lang", "Too long") : found.state === "noResults" ? tr("Niets gevonden", "Nothing found") : T.countLabel(found, findIndex)}</span>
      <button class="ghost" title={tr("Vorige", "Previous")} onclick={() => step(false)}>↑</button>
      <button class="ghost" title={tr("Volgende", "Next")} onclick={() => step(true)}>↓</button>
      <button class="ghost" title={tr("Sluit", "Close")} onclick={closeFind}>✕</button>
    </div>
  {/if}
  <div class="scroll" bind:this={scroller} {onscroll} {onwheel}>
    <div class="thread-column rows">
    {#if !shown.length}<p class="faint small">{tr("Nog niets in dit gesprek. Stuur een bericht om verder te gaan.", "Nothing in this conversation yet. Send a message to continue.")}</p>{/if}

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
            <span class="sym"><Icon name={b.tally.failed ? "alert" : "wrench"} size={13} /></span><span class="stext">{T.sentence(b.tally)}</span>
            <span class="chev" class:open={open.has("group:" + b.id)}><Icon name="chevron-right" size={13} /></span>
          </button>
          {#if open.has("group:" + b.id)}
            <div class="inner">{#each b.events as e (e.id)}{@render eventView(e)}{/each}</div>
          {/if}
        </div>
      {:else}
        <div class="group">
          <button class="summary" onclick={() => toggleBlock("fold:" + b.id)}>
            <span class="sym"><Icon name="circle-check" size={13} /></span><span class="stext">{tr("{time} gewerkt", "Worked for {time}", { time: T.duration(b.seconds) })}</span>
            <span class="chev" class:open={open.has("fold:" + b.id)}><Icon name="chevron-right" size={13} /></span>
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
        <span class="spin" class:waiting>{#if waiting}<Icon name="hand" size={13} />{:else}<Icon name="loader" size={13} />{/if}</span>
        <div class="live-text">
          <div class="live-head">
            <span class="label">{waiting ? (asking ? tr("Wacht op je antwoord…", "Waiting for your answer…") : tr("Wacht op je goedkeuring…", "Waiting for your approval…")) : (liveLine.tool ?? tr("De agent werkt…", "The agent is working…"))}</span>
            {#if run.turnStartedAt && !waiting}<span class="faint mono">{T.duration((now - Date.parse(run.turnStartedAt)) / 1000)}</span>{/if}
          </div>
          {#if liveLine.thought && !waiting}<div class="thought">{liveLine.thought}</div>{/if}
        </div>
      </div>
    {/if}

    {#if limited}
      <div class="recovery">
        <span class="rsym"><Icon name="hourglass" size={14} /></span>
        <div class="rtext">
          <strong>{tr("Gebruikslimiet bereikt", "Usage limit reached")}</strong>
          <span class="faint">{limitLine()}</span>
        </div>
        {#if run.limitResetAt}
          <button class="ghost" title={tr("Stuurt \"Continue where you left off.\" zodra de limiet vrij is. Een eigen bericht annuleert dit.", "Sends \"Continue where you left off.\" once the limit resets. A message of your own cancels this.")}
            onclick={() => workspace.act(() => workspaceApi.setAutoResume(run.id, !run.autoResume))}>
            {run.autoResume ? tr("Niet automatisch hervatten", "Don't resume automatically") : tr("Hervat bij reset", "Resume at reset")}
          </button>
        {/if}
        <button onclick={onretry}>{tr("Opnieuw", "Retry")}</button>
      </div>
    {:else if run.status === "failed" || run.status === "stopped"}
      <div class="recovery {run.status}">
        <span class="rsym"><Icon name={run.status === "failed" ? "alert" : "stop"} size={14} /></span>
        <div class="rtext">
          <strong>{run.status === "failed" ? tr("Deze beurt is mislukt.", "This turn failed.") : run.statusDetail === "interrupted" ? tr("Nook stopte terwijl de agent werkte; het proces draait niet meer.", "Nook stopped while the agent was working; the process is no longer running.") : tr("Je hebt deze beurt gestopt.", "You stopped this turn.")}</strong>
          <span class="faint">
            {run.statusDetail && run.statusDetail !== "interrupted"
              ? run.statusDetail
              : run.providerSessionId
                ? tr("Stuur een bericht of klik op Opnieuw: de agent gaat verder met dezelfde geschiedenis.", "Send a message or click Retry: the agent continues with the same history.")
                : tr("De agent meldde nog geen sessie; Opnieuw start de opdracht vanaf het begin.", "The agent hasn't reported a session yet; Retry starts the task from the beginning.")}
          </span>
        </div>
        {#if failure}<button class="ghost" onclick={() => reveal(failure)}>{tr("Ga naar fout", "Go to error")}</button>{/if}
        <button onclick={onretry}>{tr("Opnieuw", "Retry")}</button>
      </div>
    {/if}
    </div>
  </div>
  {#if !follow && !atEnd && !finding}
    <button class="to-end" onclick={() => { follow = true; toEnd(true); }}>{tr("Naar einde", "To the end")} ↓</button>
  {/if}
</div>

<style>
  .wrap { position: relative; flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; min-height: 0; overflow-y: auto; }
  .rows { display: flex; flex-direction: column; gap: 16px; padding-top: 8px; padding-bottom: 16px; }
  .find { display: flex; gap: 6px; align-items: center; padding: 4px; width: min(420px, calc(100% - 32px)); margin: 0 auto 6px; background: var(--surface); border: 1px solid var(--line2); border-radius: var(--radius-panel); }
  .find input { flex: 1; padding: 4px 8px; }
  .count { font-size: 11.5px; min-width: 70px; text-align: right; }
  /* A work group: one quiet line of 24 px, the steps under it when you open it. */
  .group { display: flex; flex-direction: column; gap: 4px; }
  .summary { display: flex; gap: 8px; align-items: center; min-height: 24px; background: none; border: none; padding: 0 4px; font-size: 14px; color: var(--text2); text-align: left; border-radius: var(--radius-control); width: fit-content; max-width: 100%; }
  .summary:hover { background: none; color: var(--paper); }
  .summary.fail { color: var(--coral); }
  .summary .sym { display: inline-flex; color: var(--text3); }
  .summary.fail .sym { color: var(--coral); }
  .stext { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .chev { display: inline-flex; transition: transform 0.15s; color: var(--text3); opacity: 0; }
  .summary:hover .chev, .chev.open { opacity: 1; }
  .chev.open { transform: rotate(90deg); }
  .inner { display: flex; flex-direction: column; gap: 4px; padding: 0 0 8px 4px; border-bottom: 1px solid color-mix(in srgb, var(--line2) 60%, transparent); }
  .inner.fold { gap: 12px; }
  /* The live line: a status line, quiet text with a spinner. */
  .live { display: flex; gap: 8px; align-items: flex-start; font-size: 12px; padding: 0 4px; color: var(--text2); }
  .spin { display: inline-flex; margin-top: 1px; color: var(--text3); animation: spin 1s linear infinite; }
  .spin.waiting { color: var(--amber); animation: none; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .live-text { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  .live-head { display: flex; gap: 6px; align-items: center; }
  .live-head .label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--text2); }
  .mono { font-family: var(--mono); font-size: 11px; }
  .thought { color: var(--text3); font-size: 12px; background: linear-gradient(90deg, var(--text3), var(--paper), var(--text3)); background-size: 200% 100%; -webkit-background-clip: text; background-clip: text; color: transparent; animation: shimmer 2.4s linear infinite; }
  @keyframes shimmer { from { background-position: 200% 0; } to { background-position: -200% 0; } }
  .recovery { display: flex; gap: 10px; align-items: center; padding: 10px 12px; border-radius: var(--radius-card); border: 1px solid color-mix(in srgb, var(--amber) 30%, var(--line2)); background: var(--surface); }
  .recovery.failed { border-color: color-mix(in srgb, var(--coral) 30%, var(--line2)); }
  .rsym { display: inline-flex; color: var(--amber); }
  .recovery.failed .rsym { color: var(--coral); }
  .rtext { flex: 1; display: flex; flex-direction: column; gap: 2px; font-size: 12px; }
  .to-end { position: absolute; bottom: 8px; left: 50%; transform: translateX(-50%); border-radius: 999px; font-size: 12px; padding: 4px 12px; background: var(--surface); box-shadow: var(--shadow-popover); }
  .small { font-size: 12.5px; }
</style>
