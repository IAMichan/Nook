<script lang="ts">
  // "Where things stand" on the empty Nook chat (`HomeGlance` on the Mac): what your coding agents are doing, what is
  // next in your calendar, how full your plan limits are and what is playing, as quiet cards two by two. Each card opens
  // the place it summarizes; a card with nothing to say (no calendar, nothing playing) leaves its place to the next.
  import { invoke } from "@tauri-apps/api/core";
  import { nook } from "../lib/state.svelte";
  import { agents } from "../lib/agents.svelte";
  import { services, serviceEvents, type NowPlaying } from "../lib/services";
  import { connectorEvents } from "../lib/connectors";
  import { when } from "../lib/inbox-sources";
  import { tr } from "../lib/i18n.svelte";
  import { time } from "../lib/whatsapp";
  import type { Target } from "../lib/inbox";
  import Ico from "./ui/Ico.svelte";
  import AgentMark from "../views/companion/ui/AgentMark.svelte";
  import { agentApi, type AgentProfile } from "../lib/agents";
  import { glanceLimits, tone } from "../lib/glance-limits";

  let { onopen }: { onopen: (target: Target) => void } = $props();

  interface UpcomingEvent { title: string; start: string; end: string; allDay: boolean; location: string; calendar: string }

  const local = $derived(!!nook.info?.capabilities.localAgents);
  $effect(() => {
    if (local) void agents.start();
  });
  // Sessions that need you first, then the ones at work.
  const busy = $derived(
    agents.sessions
      .filter((s) => s.status === "waiting" || s.status === "running" || !!s.approvalId)
      .sort((a, b) => {
        const aw = a.status === "waiting" || !!a.approvalId ? 0 : 1;
        const bw = b.status === "waiting" || !!b.approvalId ? 0 : 1;
        return aw !== bw ? aw - bw : (b.updated ?? "").localeCompare(a.updated ?? "");
      }),
  );
  const waitingCount = $derived(busy.filter((s) => s.status === "waiting" || !!s.approvalId).length);
  const workingCount = $derived(busy.length - waitingCount);
  const agentsStatus = $derived.by(() => {
    const parts: string[] = [];
    if (waitingCount > 0) parts.push(tr("{n} wacht op je", "{n} need you", { n: waitingCount }));
    if (workingCount > 0) parts.push(tr("{n} bezig", "{n} working", { n: workingCount }));
    return parts.join(" · ");
  });

  // The rest of today's calendar, from the linked calendars' cache; null while there is no calendar to read.
  let events = $state<UpcomingEvent[] | null>(null);
  let nowTick = $state(Date.now());
  const loadEvents = () =>
    invoke<UpcomingEvent[]>("agenda_upcoming", { hours: 24 })
      .then((list) => {
        const now = Date.now();
        const endOfDay = new Date(now);
        endOfDay.setHours(24, 0, 0, 0);
        events = list.filter((e) => !e.allDay && Date.parse(e.end) > now && Date.parse(e.start) < endOfDay.getTime());
      })
      .catch(() => (events = null));
  $effect(() => {
    loadEvents();
    const timer = setInterval(() => {
      nowTick = Date.now();
      loadEvents();
    }, 60_000);
    const un = connectorEvents.onChanged(loadEvents);
    return () => {
      clearInterval(timer);
      un.then((f) => f());
    };
  });
  const next = $derived(events?.[0] ?? null);
  const nextIsNow = $derived(!!next && Date.parse(next.start) <= nowTick);
  function compactDuration(ms: number): string {
    const mins = Math.max(1, Math.round(ms / 60_000));
    if (mins < 60) return `${mins}m`;
    const h = Math.floor(mins / 60);
    const m = mins % 60;
    return m ? `${h}h ${m}m` : `${h}h`;
  }
  const agendaStatus = $derived.by(() => {
    if (!next) return "";
    if (nextIsNow) return tr("Nu", "Now");
    return tr("over {time}", "in {time}", { time: compactDuration(Date.parse(next.start) - nowTick) });
  });

  let track = $state<NowPlaying | null>(null);
  $effect(() => {
    if (!nook.info?.capabilities.media) return;
    services.nowPlaying().then((n) => (track = n)).catch(() => {});
    const un = serviceEvents.onNowPlaying((n) => (track = n));
    return () => {
      un.then((f) => f());
    };
  });
  const trackSub = $derived(track ? [track.artist, track.app].filter(Boolean).join(" · ") : "");

  // Per signed-in account its fullest plan window: what you would run out of first.
  let profiles = $state<AgentProfile[]>([]);
  $effect(() => {
    if (local) agentApi.profiles().then((p) => (profiles = p)).catch(() => {});
  });
  const limits = $derived(local ? glanceLimits(agents.overview?.planUsage, agents.overview?.profilePlanUsage ?? {}, profiles) : []);
  const fullest = $derived(limits[0]?.used ?? 0);

  const title = (s: (typeof busy)[number]) => s.summary || s.lastPrompt || s.project || s.name;
</script>

<div class="glance">
  <button class="card" onclick={() => onopen(busy[0] ? { kind: "agents", select: busy[0].id } : { kind: "route", route: "agents" })}>
    <span class="head">
      <span class="ico"><Ico name="code" size={12} stroke={2.1} /></span>
      <span class="card-title">{tr("Agents", "Agents")}</span>
      {#if agentsStatus}<span class="status" class:amber={waitingCount > 0}>{agentsStatus}</span>{/if}
      <span class="chev" class:pull={!agentsStatus}><Ico name="chevron-right" size={11} stroke={2.4} /></span>
    </span>
    {#if !local}
      <span class="quiet">{tr("Agents draaien op je computer.", "Agents run on your computer.")}</span>
    {:else if busy.length === 0}
      <span class="quiet">{tr("Geen agent aan het werk", "No agent at work")}</span>
    {:else}
      <span class="rows">
        {#each busy.slice(0, 3) as s (s.id)}
          {@const waits = s.status === "waiting" || !!s.approvalId}
          <span class="line">
            <AgentMark agent={s.name} size={14} />
            <span class="ellipsis">{title(s)}</span>
            <span class="state-dot" class:waiting={waits} class:working={!waits}></span>
          </span>
        {/each}
        {#if busy.length > 3}<span class="more">{tr("+{n} meer", "+{n} more", { n: busy.length - 3 })}</span>{/if}
      </span>
    {/if}
  </button>

  {#if events}
    <button class="card" onclick={() => next && onopen({ kind: "newNook", ask: tr("Help me me voor te bereiden op \"{title}\" ({when}).", "Help me prepare for \"{title}\" ({when}).", { title: next.title, when: when(next.start) }) })}>
      <span class="head">
        <span class="ico"><Ico name="calendar" size={12} stroke={2.1} /></span>
        <span class="card-title">{tr("Agenda", "Calendar")}</span>
        {#if agendaStatus}<span class="status" class:mint={nextIsNow}>{agendaStatus}</span>{/if}
        <span class="chev" class:pull={!agendaStatus}><Ico name="chevron-right" size={11} stroke={2.4} /></span>
      </span>
      {#if events.length}
        <span class="rows">
          {#each events.slice(0, 3) as ev, i (`${ev.start}-${ev.title}-${i}`)}
            <span class="line">
              <span class="ev-bar" class:first={i === 0}></span>
              <span class="ev-time">{time(ev.start)}</span>
              <span class="ellipsis">{ev.title}</span>
            </span>
          {/each}
          {#if events.length > 3}<span class="more">{tr("+{n} meer", "+{n} more", { n: events.length - 3 })}</span>{/if}
        </span>
      {:else}
        <span class="quiet">{tr("Niets meer gepland vandaag", "Nothing else planned today")}</span>
      {/if}
    </button>
  {/if}

  {#if limits.length}
    <button class="card" onclick={() => onopen({ kind: "workspace", page: "usage" })}>
      <span class="head">
        <span class="ico"><Ico name="gauge" size={12} stroke={2.1} /></span>
        <span class="card-title">{tr("Limieten", "Limits")}</span>
        {#if tone(fullest) !== "calm"}<span class="status {tone(fullest)}">{tr("Bijna vol", "Nearly full")}</span>{/if}
        <span class="chev" class:pull={tone(fullest) === "calm"}><Ico name="chevron-right" size={11} stroke={2.4} /></span>
      </span>
      <span class="limits">
        {#each limits.slice(0, 3) as limit (limit.id)}
          <span class="limit">
            <span class="line">
              <span class="ellipsis">{limit.name} · {limit.window === "5h" ? tr("5 uur", "5 hours") : tr("week", "week")}</span>
              <span class="pct {tone(limit.used)}">{limit.used}%</span>
            </span>
            <span class="bar"><span class="fill {tone(limit.used)}" style:width="{Math.min(100, limit.used)}%"></span></span>
          </span>
        {/each}
      </span>
    </button>
  {/if}

  {#if track}
    <div class="card music" role="button" tabindex="0" onclick={() => onopen({ kind: "route", route: "music" })}
      onkeydown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onopen({ kind: "route", route: "music" }); } }}>
      <span class="head">
        <span class="ico"><Ico name="music" size={12} stroke={2.1} /></span>
        <span class="card-title">{tr("Muziek", "Music")}</span>
        <span class="status" class:mint={track.playing}>{track.playing ? tr("speelt", "playing") : tr("gepauzeerd", "paused")}</span>
        <span class="chev"><Ico name="chevron-right" size={11} stroke={2.4} /></span>
      </span>
      <span class="now">
        <span class="what">
          <span class="track-title ellipsis">{track.title}</span>
          {#if trackSub}<span class="track-sub ellipsis">{trackSub}</span>{/if}
        </span>
        <button class="ghost play" title={track.playing ? tr("Pauzeer", "Pause") : tr("Speel af", "Play")} aria-label={track.playing ? tr("Pauzeer", "Pause") : tr("Speel af", "Play")}
          onclick={(e) => { e.stopPropagation(); services.media("playPause").catch(() => {}); }}>
          <Ico name={track.playing ? "pause" : "play"} size={12} fill="currentColor" stroke={1.6} />
        </button>
      </span>
    </div>
  {/if}
</div>

<style>
  .glance { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: var(--space-8); }
  .card {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: var(--space-8);
    min-width: 0;
    padding: var(--space-12);
    text-align: left;
    background: var(--field);
    border: 0;
    border-radius: var(--radius-panel);
    color: var(--text2);
    cursor: pointer;
    transition: background var(--motion-hover);
  }
  .card:hover:not(:disabled) { background: var(--graphite); border-color: transparent; }

  .head { display: flex; align-items: center; gap: var(--space-6); min-width: 0; }
  .ico { width: 14px; flex: none; display: inline-flex; align-items: center; justify-content: center; color: var(--text3); }
  .card-title { font: var(--text-label); color: var(--text2); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .status { margin-left: auto; font: var(--text-caption); color: var(--text3); white-space: nowrap; flex: none; }
  .status.amber, .status.warning, .pct.warning { color: var(--amber); }
  .status.mint { color: var(--mint); }
  .status.error, .pct.error { color: var(--coral); }
  .chev { display: inline-flex; color: var(--text3); opacity: 0; transition: opacity var(--motion-hover); flex: none; }
  .chev.pull { margin-left: auto; }
  .card:hover .chev, .card:focus-visible .chev { opacity: 1; }

  .rows { display: flex; flex-direction: column; gap: var(--space-6); min-width: 0; }
  .line { display: flex; align-items: center; gap: var(--space-6); min-width: 0; font: var(--text-detail); color: var(--text-strong); }
  .ellipsis { min-width: 0; overflow: hidden; white-space: nowrap; text-overflow: ellipsis; }
  .line .ellipsis { flex: 1; }
  .state-dot { width: 6px; height: 6px; border-radius: 999px; flex: none; margin-left: var(--space-4); }
  .state-dot.waiting { background: var(--amber); }
  .state-dot.working { background: var(--iris); }
  .quiet { font: var(--text-detail); color: var(--text3); }
  .more { font: var(--text-caption); color: var(--text3); }

  .ev-bar { width: 3px; height: 14px; border-radius: 999px; flex: none; background: var(--line2); }
  .ev-bar.first { background: var(--iris); }
  .ev-time { flex: none; font: var(--text-caption); font-family: var(--mono); font-variant-numeric: tabular-nums; color: var(--text2); }

  .limits { display: flex; flex-direction: column; gap: var(--space-8); min-width: 0; }
  .limit { display: flex; flex-direction: column; gap: var(--space-4); }
  .pct { flex: none; font: var(--text-caption); font-family: var(--mono); font-variant-numeric: tabular-nums; color: var(--text-strong); }
  .bar { height: 4px; border-radius: 999px; background: var(--line); overflow: hidden; }
  .fill { display: block; height: 100%; background: var(--text2); border-radius: 999px; }
  .fill.warning { background: var(--amber); }
  .fill.error { background: var(--coral); }

  .now { display: flex; align-items: center; gap: var(--space-8); min-width: 0; }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; gap: var(--space-2); }
  .track-title { font: var(--text-detail); font-weight: 500; color: var(--text-strong); }
  .track-sub { font: var(--text-caption); color: var(--text3); }
  .play { width: 28px; height: 28px; padding: 0; flex: none; border-radius: var(--radius-control); display: grid; place-items: center; color: var(--text2); }
  .play:hover { background: var(--smoke); color: var(--paper); }

  @media (max-width: 640px) { .glance { grid-template-columns: minmax(0, 1fr); } }
</style>
