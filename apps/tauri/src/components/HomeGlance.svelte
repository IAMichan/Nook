<script lang="ts">
  // "Where things stand" on the empty Nook chat (`HomeGlance` on the Mac): what your coding agents are doing, what is
  // next in your calendar, and what is playing, as quiet cards two by two. Each card opens the place it summarizes; a
  // card with nothing to say (no calendar, nothing playing) leaves its place to the next.
  import { invoke } from "@tauri-apps/api/core";
  import { nook } from "../lib/state.svelte";
  import { agents } from "../lib/agents.svelte";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import { connectorEvents } from "../lib/connectors";
  import { when } from "../lib/inbox-sources";
  import { tr } from "../lib/i18n.svelte";
  import type { Target } from "../lib/inbox";
  import Icon from "./Icon.svelte";

  let { onopen }: { onopen: (target: Target) => void } = $props();

  interface UpcomingEvent { title: string; start: string; end: string; allDay: boolean; location: string; calendar: string }

  const local = $derived(!!nook.info?.capabilities.localAgents);
  $effect(() => {
    if (local) void agents.start();
  });
  // Sessions that need you first, then the ones at work.
  const busy = $derived(
    agents.sessions
      .filter((s) => s.status === "waiting" || s.status === "running")
      .sort((a, b) => (a.status === b.status ? (b.updated ?? "").localeCompare(a.updated ?? "") : a.status === "waiting" ? -1 : 1)),
  );

  // The rest of today's calendar, from the linked calendars' cache; null while there is no calendar to read.
  let events = $state<UpcomingEvent[] | null>(null);
  const loadEvents = () =>
    invoke<UpcomingEvent[]>("agenda_upcoming", { hours: 24 })
      .then((list) => (events = list.filter((e) => !e.allDay && Date.parse(e.end) > Date.now())))
      .catch(() => (events = null));
  $effect(() => {
    loadEvents();
    const timer = setInterval(loadEvents, 5 * 60_000);
    const un = connectorEvents.onChanged(loadEvents);
    return () => {
      clearInterval(timer);
      un.then((f) => f());
    };
  });
  const next = $derived(events?.[0] ?? null);

  let track = $state<NowPlaying | null>(null);
  $effect(() => {
    if (!nook.info?.capabilities.media) return;
    services.nowPlaying().then((n) => (track = n)).catch(() => {});
    const un = serviceEvents.onNowPlaying((n) => (track = n));
    return () => {
      un.then((f) => f());
    };
  });

  const title = (s: (typeof busy)[number]) => s.summary || s.lastPrompt || s.project || s.name;
</script>

<div class="glance">
  <button class="card" onclick={() => onopen(busy[0] ? { kind: "agents", select: busy[0].id } : { kind: "route", route: "agents" })}>
    <span class="head"><Icon name="agents" size={14} /><span>{tr("Agents", "Agents")}</span>
      {#if busy.length}<span class="count">{busy.length}</span>{/if}</span>
    {#if !local}
      <span class="quiet">{tr("Agents draaien op je computer.", "Agents run on your computer.")}</span>
    {:else if busy.length === 0}
      <span class="quiet">{tr("Er werkt nu geen agent.", "No agent is working right now.")}</span>
    {:else}
      {#each busy.slice(0, 3) as s (s.id)}
        <span class="line"><span class="dot" class:waiting={s.status === "waiting"} class:working={s.status === "running"}></span><span class="ellipsis">{title(s)}</span><span class="faint who">{s.name}</span></span>
      {/each}
    {/if}
  </button>

  {#if events}
    <button class="card" onclick={() => next && onopen({ kind: "newNook", ask: tr("Help me me voor te bereiden op \"{title}\" ({when}).", "Help me prepare for \"{title}\" ({when}).", { title: next.title, when: when(next.start) }) })}>
      <span class="head"><Icon name="calendar" size={14} /><span>{tr("Agenda", "Calendar")}</span></span>
      {#if next}
        <span class="line strong"><span class="ellipsis">{next.title}</span></span>
        <span class="quiet">{when(next.start)}{next.location ? ` · ${next.location}` : ""}</span>
        {#if events.length > 1}<span class="faint more">{tr("en nog {n} vandaag", "and {n} more today", { n: events.length - 1 })}</span>{/if}
      {:else}
        <span class="quiet">{tr("Niets meer in je agenda vandaag.", "Nothing else in your calendar today.")}</span>
      {/if}
    </button>
  {/if}

  {#if track}
    <div class="card music" role="button" tabindex="0" onclick={() => onopen({ kind: "route", route: "music" })}
      onkeydown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onopen({ kind: "route", route: "music" }); } }}>
      <span class="head"><Icon name="voice" size={14} /><span>{tr("Speelt nu", "Now playing")}</span></span>
      <span class="now">
        {#if track.artwork}<img src={track.artwork} alt="" />{/if}
        <span class="what"><span class="line strong"><span class="ellipsis">{track.title}</span></span><span class="quiet ellipsis">{track.artist}</span></span>
        <button class="ghost play" title={track.playing ? tr("Pauzeer", "Pause") : tr("Speel af", "Play")} aria-label={track.playing ? tr("Pauzeer", "Pause") : tr("Speel af", "Play")}
          onclick={(e) => { e.stopPropagation(); services.media("playPause").catch(() => {}); }}>{track.playing ? "❚❚" : "▶"}</button>
      </span>
    </div>
  {/if}
</div>

<style>
  .glance { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-8); }
  .card { display: flex; flex-direction: column; align-items: stretch; gap: var(--space-6); min-width: 0; padding: var(--space-12) var(--space-16); text-align: left; background: var(--field); border: 0; border-radius: var(--radius-panel); color: var(--text2); cursor: pointer; transition: background 120ms ease; }
  .card:hover:not(:disabled) { background: var(--graphite); border-color: transparent; }
  .head { display: flex; align-items: center; gap: var(--space-6); font: var(--text-label); color: var(--text3); margin-bottom: var(--space-2); }
  .count { margin-left: auto; font: var(--text-caption); color: var(--paper); background: var(--smoke); border-radius: var(--radius-pill); padding: 1px 7px; }
  .line { display: flex; align-items: center; gap: var(--space-6); min-width: 0; font: var(--text-detail); color: var(--text-strong); }
  .line.strong { font: var(--text-body); font-weight: 500; color: var(--paper); }
  .ellipsis { min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .line .ellipsis { flex: 1; }
  .who { flex: none; font: var(--text-caption); }
  .quiet { font: var(--text-detail); color: var(--text2); }
  .more { font: var(--text-caption); }
  .now { display: flex; align-items: center; gap: var(--space-12); min-width: 0; }
  .now img { width: 36px; height: 36px; flex: none; border-radius: var(--radius-chip); object-fit: cover; }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .play { width: 28px; height: 28px; padding: 0; flex: none; font-size: 10px; display: grid; place-items: center; }
  @media (max-width: 640px) { .glance { grid-template-columns: minmax(0, 1fr); } }
</style>
