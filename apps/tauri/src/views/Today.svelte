<script lang="ts">
  // Vandaag: wat je nu nodig hebt. Een gemist aanbod van meedenken, een gesprek dat genoteerd wordt of net klaar is,
  // op maandag het overzicht van je week, en je open punten (beloftes en taken die Nook bijhoudt).
  import { api, events } from "../lib/api";
  import { services, serviceEvents, type TodayItem, type RecapView, type NoteLive } from "../lib/services";
  import { nook, relativeTime } from "../lib/state.svelte";
  import { renderMarkdown } from "../lib/markdown";
  import type { OpenLoop } from "../lib/types";

  let loops = $state<OpenLoop[]>([]);
  let items = $state<TodayItem[]>([]);
  let live = $state<NoteLive | null>(null);
  let recap = $state<RecapView | null>(null);
  let note = $state<string | null>(null);

  const load = () => {
    api.openLoops().then((l) => (loops = l));
    services.today().then((t) => (items = t)).catch(() => (items = []));
  };

  $effect(() => {
    load();
    services.noteLive().then((l) => (live = l)).catch(() => {});
    const timer = setInterval(load, 30_000);
    const a = serviceEvents.onNudge(() => load());
    const b = serviceEvents.onNoteLive((l) => {
      const changed = l.recording !== live?.recording;
      live = l;
      if (changed) load();
    });
    const c = events.onNookUpdated(() => load());
    return () => {
      clearInterval(timer);
      a.then((f) => f());
      b.then((f) => f());
      c.then((f) => f());
    };
  });

  async function done(id: string) {
    await api.completeLoop(id);
    load();
  }

  async function open(item: TodayItem) {
    if (item.kind === "nudge") {
      await services.answerNudge(item.id, "open");
    } else if (item.kind === "recording") {
      await services.toggleNote();
    } else if (item.kind === "note") {
      note = await services.noteMarkdown(item.id);
    } else if (item.kind === "recap") {
      recap = await services.recap();
    }
    load();
  }

  async function showRecap() {
    recap = await services.recap();
  }

  const facts = $derived(
    recap
      ? [
          ["tijd met agents", recap.duration],
          ["sessies", String(recap.summary.sessions)],
          ["opdrachten", String(recap.summary.prompts)],
          ["regels erbij / eraf", `+${recap.summary.linesAdded} −${recap.summary.linesRemoved}`],
          ["commando's", String(recap.summary.commands)],
          ["toegestaan / geweigerd", `${recap.summary.allowed} / ${recap.summary.denied}`],
          ...(recap.busiest ? [["drukste dag", recap.busiest]] : []),
          ...(recap.summary.topProject ? [["meeste tijd in", recap.summary.topProject]] : []),
        ]
      : [],
  );
</script>

<section class="today">
  {#if recap}
    <div class="panel">
      <div class="head"><span class="faint">{recap.label}</span><button class="ghost x" onclick={() => (recap = null)}>✕</button></div>
      {#if recap.summary.prompts === 0 && recap.summary.sessions === 0}
        <p class="muted">Ik heb nog niets bijgehouden. Koppel je agents bij Instellingen › Agents, dan zie je hier wat ze voor je deden.</p>
      {:else}
        <p><strong>{recap.summary.topAgent ? `${recap.summary.topAgent} en co` : "Je agents"} werkten {recap.duration} voor je.</strong></p>
        <dl>
          {#each facts as [label, value] (label)}<dt>{label}</dt><dd>{value}</dd>{/each}
        </dl>
      {/if}
    </div>
  {:else if note}
    <div class="panel">
      <div class="head"><span class="faint">Gespreksnotitie</span><button class="ghost x" onclick={() => (note = null)}>✕</button></div>
      <div class="markdown note">{@html renderMarkdown(note)}</div>
    </div>
  {/if}

  {#if items.length}
    <h4>Vandaag</h4>
    {#each items as item (item.id)}
      <div class="item {item.kind}">
        <span class="dot" class:waiting={item.kind === "nudge"} class:error={item.kind === "recording"} class:unread={item.kind === "recap" || item.kind === "note"}></span>
        <div class="what">
          <span>{item.title}</span>
          <span class="faint">{item.subtitle}</span>
        </div>
        <button class="small" onclick={() => open(item)}>{item.action}</button>
      </div>
    {/each}
  {/if}

  <h4>Open punten</h4>
  {#each loops as loop (loop.id)}
    <div class="loop">
      <button class="check" title="Afvinken" onclick={() => done(loop.id)}>○</button>
      <span>{loop.title}</span>
      {#if loop.due}<span class="faint">{new Date(loop.due).toLocaleString("nl-NL", { weekday: "short", hour: "2-digit", minute: "2-digit" })}</span>
      {:else}<span class="faint">{relativeTime(loop.created)}</span>{/if}
    </div>
  {:else}
    <p class="faint">Niets open. Zeg bijvoorbeeld "onthoud dat ik Lisa terugbel".</p>
  {/each}

  {#if nook.info?.capabilities.desktop}
    <div class="more">
      {#if nook.info.capabilities.microphone}
        <button class="ghost small" onclick={() => services.toggleNote()}>{live?.recording ? "■ Opname stoppen" : "● Gesprek noteren"}</button>
      {/if}
      <button class="ghost small" onclick={showRecap}>Weekoverzicht</button>
    </div>
    {#if live?.problem}<p class="err">{live.problem}</p>{/if}
  {/if}
</section>

<style>
  .today { padding: 12px 16px; }
  h4 { margin: 0 0 8px; font-size: 12px; color: var(--text2); text-transform: uppercase; letter-spacing: 0.04em; }
  h4:not(:first-child) { margin-top: 14px; }
  .loop { display: flex; gap: 8px; align-items: center; padding: 4px 0; }
  .loop span:nth-child(2) { flex: 1; }
  .check { padding: 0 6px; background: none; border: none; color: var(--text2); }
  .check:hover { color: var(--mint); background: none; }
  .item { display: flex; gap: 8px; align-items: center; padding: 5px 0; }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .what span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .what .faint { font-size: 11px; }
  .small { font-size: 11px; padding: 3px 8px; }
  .panel { background: var(--graphite); border: 1px solid var(--line2); border-radius: 12px; padding: 8px 12px 12px; margin-bottom: 12px; }
  .head { display: flex; justify-content: space-between; align-items: center; font-size: 11px; text-transform: uppercase; letter-spacing: 0.04em; }
  .x { padding: 2px 6px; }
  dl { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 3px 10px; margin: 6px 0 0; font-size: 12px; }
  dt { color: var(--text2); }
  dd { margin: 0; white-space: nowrap; text-align: right; max-width: 120px; overflow: hidden; text-overflow: ellipsis; }
  .note { max-height: 260px; overflow-y: auto; font-size: 12px; }
  .more { display: flex; gap: 4px; margin-top: 14px; flex-wrap: wrap; }
  .err { color: var(--coral); font-size: 11px; }
</style>
