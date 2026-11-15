<script lang="ts">
  // The Agents tab of the iPhone app (`SessionListView`): the header with Pull requests and New session, a card per
  // session that needs you, then the shelves Working and Recent (the first eight, then Show more), a search once there
  // are more than eight. Touch and hold a row for snooze, archive and end.
  import {
    actionLabel, companion, has, matchesSession, may, needsYouState, sortSessions, Feature,
    type ClientView, type SessionDigest,
  } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import PanelHeader from "./ui/PanelHeader.svelte";
  import ConnectionLine from "./ui/ConnectionLine.svelte";
  import IconButton from "./ui/IconButton.svelte";
  import SearchField from "./ui/SearchField.svelte";
  import SessionNotice from "./ui/SessionNotice.svelte";
  import ShelfHeader from "./ui/ShelfHeader.svelte";
  import AgentRow from "./ui/AgentRow.svelte";
  import EmptyState from "./ui/EmptyState.svelte";
  import Menu, { type MenuItem } from "./ui/Menu.svelte";
  import Sheet from "./ui/Sheet.svelte";
  import PullRequests from "./PullRequests.svelte";
  import SnoozePicker from "./SnoozePicker.svelte";

  let { view, act, took, onorb, ongear, onopen, onnew }: {
    view: ClientView;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    took: (v: ClientView) => void;
    onorb: (r: DOMRect) => void;
    ongear: () => void;
    onopen: (id: string, digest?: SessionDigest) => void;
    onnew: () => void;
  } = $props();

  // Older sessions than the live list holds, a page at a time, and the Mac's search through all of them (`history`).
  const canHistory = $derived(has(view, Feature.history) && may(view, "read"));
  let older = $state<SessionDigest[]>([]);
  let olderCursor = $state<string | null | undefined>(undefined);
  let olderLoading = $state(false);
  let matches = $state<SessionDigest[]>([]);
  let matchCursor = $state<string | null | undefined>(undefined);
  let matchLoading = $state(false);
  const live = $derived(new Set(view.sessions.map((s) => s.id)));

  async function page(text: string, cursor: string | null | undefined) {
    const r = await companion.call({ op: "history", text: text || undefined, item: cursor ?? undefined });
    if (!r.response) took(r.view);
    return { sessions: (r.response?.sessions ?? []).filter((s) => !live.has(s.id)), cursor: r.response?.cursor ?? null };
  }
  async function moreOlder() {
    olderLoading = true;
    const p = await page("", olderCursor);
    older = [...older, ...p.sessions.filter((s) => !older.some((o) => o.id === s.id))];
    olderCursor = p.cursor;
    olderLoading = false;
  }
  async function moreMatches(text: string, fresh: boolean) {
    matchLoading = true;
    const p = await page(text, fresh ? undefined : matchCursor);
    if (text !== query.trim()) return;
    matches = fresh ? p.sessions : [...matches, ...p.sessions];
    matchCursor = p.cursor;
    matchLoading = false;
  }
  $effect(() => {
    const text = query.trim();
    if (!canHistory || !text) { matches = []; matchCursor = undefined; return; }
    const timer = setTimeout(() => moreMatches(text, true), 350);
    return () => clearTimeout(timer);
  });

  const SHOWN = 8;
  let query = $state("");
  let more = $state(false);
  let header = $state<HTMLDivElement | null>(null);
  let menu = $state<{ session: SessionDigest; anchor: DOMRect } | null>(null);
  let blocked = $state<string | null>(null);
  let pulls = $state(false);
  let picking = $state<SessionDigest | null>(null);
  let open = $state<Record<string, boolean>>(readShelves());

  function readShelves(): Record<string, boolean> {
    try { return JSON.parse(localStorage.getItem("companion.shelves") ?? "{}"); } catch { return {}; }
  }
  function toggle(shelf: string) {
    haptic();
    open[shelf] = !(open[shelf] ?? true);
    try { localStorage.setItem("companion.shelves", JSON.stringify(open)); } catch { /* remembered for this visit */ }
  }

  const needs = (s: SessionDigest) => s.items.length > 0 || needsYouState(s.attention);
  const all = $derived(sortSessions(view.sessions).filter((s) => !query.trim() || matchesSession(s, query)));
  const waiting = $derived(all.filter(needs));
  const working = $derived(all.filter((s) => !needs(s) && s.attention === "working"));
  const recent = $derived(all.filter((s) => !needs(s) && s.attention !== "working").sort((a, b) => b.updated - a.updated));
  const shownRecent = $derived(more || query.trim() ? recent : recent.slice(0, SHOWN));

  function newSession() {
    if (!has(view, Feature.start)) return void (blocked = tr("Deze Mac kan nog geen sessies starten vanaf de telefoon. Werk Nook bij op je Mac.", "This Mac cannot start sessions from the phone yet. Update Nook on your Mac."));
    if (!may(view, "operate")) return void (blocked = tr("Sessies starten staat uit voor deze iPhone in Nook op je Mac.", "Starting sessions is turned off for this phone in Nook on your Mac."));
    haptic();
    onnew();
  }

  async function manage(session: SessionDigest, action: string) {
    haptic();
    const r = await companion.call({ op: "manage", session: session.id, item: action });
    took(r.view);
  }

  const menuSections = $derived.by<MenuItem[][]>(() => {
    if (!menu) return [];
    const s = menu.session;
    const offered = new Set(has(view, Feature.manage) && may(view, "operate") ? (s.actions ?? []) : []);
    const snooze: MenuItem[] = offered.has("unsnooze")
      ? [{ label: tr("Snooze opheffen", "Cancel snooze"), icon: "alarm-clock", onselect: () => manage(s, "unsnooze") }]
      : [
          ...(offered.has("snoozeHour") ? [{ label: tr("Een uur", "One hour"), icon: "clock", onselect: () => manage(s, "snoozeHour") }] : []),
          ...(offered.has("snoozeEvening") ? [{ label: tr("Vanavond", "This evening"), icon: "clock", onselect: () => manage(s, "snoozeEvening") }] : []),
          ...(offered.has("snoozeTomorrow") ? [{ label: tr("Morgenochtend", "Tomorrow morning"), icon: "clock", onselect: () => manage(s, "snoozeTomorrow") }] : []),
          ...(offered.has("snoozeLimitReset") && s.limitResetsAt ? [{ label: tr("Tot de limiet reset", "Until the limit resets"), icon: "gauge", onselect: () => manage(s, "snoozeLimitReset") }] : []),
          ...(offered.has("snoozeUntil") ? [{ label: tr("Kies een moment…", "Pick a time…"), icon: "calendar-clock", onselect: () => (picking = s) }] : []),
        ];
    const end: MenuItem[] = [
      ...(offered.has("archive") ? [{ label: actionLabel("archive"), icon: "archive", destructive: true, onselect: () => manage(s, "archive") }] : []),
      ...(offered.has("end") ? [{ label: tr("Beëindig sessie", "End session"), icon: "circle-x", destructive: true, onselect: () => manage(s, "end") }] : []),
    ];
    return [snooze, end];
  });
</script>

<div class="tab">
  <div class="scroll">
    <div bind:this={header}>
      <PanelHeader title={tr("Agents", "Agents")} {view} onorb={() => header && onorb((header.querySelector(".orb") as HTMLElement).getBoundingClientRect())} {ongear}>
        {#snippet buttons()}
          {#if has(view, Feature.pullRequests) && may(view, "read")}<IconButton icon="git-pull-request" label={tr("Pull requests", "Pull requests")} onclick={() => { haptic(); pulls = true; }} />{/if}
          <IconButton icon="square-pen" label={tr("Nieuwe sessie", "New session")} onclick={newSession} />
        {/snippet}
      </PanelHeader>
    </div>
    <div class="top">
      <ConnectionLine {view} />
      {#if view.sessions.length > SHOWN || canHistory}<SearchField bind:value={query} placeholder={tr("Zoek sessies", "Search sessions")} />{/if}
      {#if query.trim() && !all.length && !matches.length && !matchLoading}<p class="none">{tr("Geen sessie gevonden.", "No session matches.")}</p>{/if}
      {#each waiting as s (s.id)}
        <SessionNotice {view} session={s} onopen={() => onopen(s.id)} {act} />
      {/each}
    </div>

    {#if working.length}
      <ShelfHeader title={tr("Aan het werk", "Working")} count={working.length} open={open.working ?? true} ontoggle={() => toggle("working")} />
      {#if open.working ?? true}
        {#each working as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id)} onhold={(r) => (menu = { session: s, anchor: r })} />{/each}
      {/if}
    {/if}
    {#if recent.length}
      <ShelfHeader title={tr("Recent", "Recent")} count={recent.length} open={open.recent ?? true} ontoggle={() => toggle("recent")} />
      {#if open.recent ?? true}
        {#each shownRecent as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id)} onhold={(r) => (menu = { session: s, anchor: r })} />{/each}
        {#if shownRecent.length < recent.length}
          <button class="more press" onclick={() => (more = true)}>{tr("Toon er nog {n}", "Show {n} more", { n: recent.length - shownRecent.length })}</button>
        {/if}
      {/if}
    {/if}

    {#if canHistory && !query.trim() && (open.recent ?? true) && shownRecent.length === recent.length}
      {#if older.length}
        <ShelfHeader title={tr("Ouder", "Older")} count={older.length} open={open.older ?? true} ontoggle={() => toggle("older")} />
        {#if open.older ?? true}{#each older as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id, s)} />{/each}{/if}
      {/if}
      {#if olderCursor !== null}
        <button class="more press" disabled={olderLoading} onclick={moreOlder}>{#if olderLoading}<span class="mini"></span>{:else}{older.length ? tr("Meer oudere sessies tonen", "Show more older sessions") : tr("Oudere sessies tonen", "Show older sessions")}{/if}</button>
      {/if}
    {/if}
    {#if canHistory && query.trim() && (matches.length || matchLoading)}
      <h3 class="older">{tr("Oudere treffers", "Older matches")}</h3>
      {#each matches as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id, s)} />{/each}
      {#if matchCursor || matchLoading}
        <button class="more press" disabled={matchLoading} onclick={() => moreMatches(query.trim(), false)}>{#if matchLoading}<span class="mini"></span>{:else}{tr("Meer treffers", "More matches")}{/if}</button>
      {/if}
    {/if}

    {#if !view.sessions.length && view.phase === "connected"}
      <EmptyState icon="layers" title={tr("Geen sessies", "No sessions")} text={tr("Sessies van je coding-agents op je Mac verschijnen hier.", "Sessions of your coding agents on your Mac show up here.")} action={tr("Nieuwe sessie", "New session")} onaction={newSession} />
    {/if}
  </div>
</div>

{#if picking}
  {@const target = picking}
  <Sheet onclose={() => (picking = null)}><SnoozePicker title={target.title} onclose={() => (picking = null)} onpick={async (at) => { const r = await companion.call({ op: "manage", session: target.id, item: "snoozeUntil", text: String(at) }); took(r.view); }} /></Sheet>
{/if}
{#if pulls}
  <Sheet onclose={() => (pulls = false)}><PullRequests {view} {took} onclose={() => (pulls = false)} onstarted={(id) => { pulls = false; onopen(id); }} /></Sheet>
{/if}
{#if menu}<Menu sections={menuSections} anchor={menu.anchor} onclose={() => (menu = null)} />{/if}
{#if blocked}
  <div class="alert-scrim"><div class="alert"><p>{blocked}</p><button onclick={() => (blocked = null)}>OK</button></div></div>
{/if}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px; }
  .none { margin: 0; padding: 24px 0; text-align: center; font: var(--pt-body); color: var(--text2); }
  .older { margin: 0; padding: 16px 20px 4px; font: var(--pt-label); color: var(--text3); }
  .mini { display: inline-block; width: 12px; height: 12px; border-radius: 50%; border: 2px solid var(--text3); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .more { width: calc(100% - 16px); margin: 0 8px; min-height: 40px; font: var(--pt-label) !important; color: var(--text2) !important; }
  .alert-scrim { position: fixed; inset: 0; z-index: 60; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; }
  .alert { width: 270px; background: rgba(37, 37, 37, 0.96); border-radius: 14px; overflow: hidden; text-align: center; }
  .alert p { margin: 0; padding: 20px 16px; font: var(--pt-control); }
  .alert button { width: 100%; height: 44px; border-top: 0.5px solid rgba(255, 255, 255, 0.12) !important; color: var(--blue) !important; font: 600 17px var(--font) !important; }
</style>
