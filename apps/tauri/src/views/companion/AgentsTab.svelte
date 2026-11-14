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

  let { view, act, took, onorb, ongear, onopen, onnew }: {
    view: ClientView;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    took: (v: ClientView) => void;
    onorb: (r: DOMRect) => void;
    ongear: () => void;
    onopen: (id: string) => void;
    onnew: () => void;
  } = $props();

  const SHOWN = 8;
  let query = $state("");
  let more = $state(false);
  let header = $state<HTMLDivElement | null>(null);
  let menu = $state<{ session: SessionDigest; anchor: DOMRect } | null>(null);
  let blocked = $state<string | null>(null);
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
          <IconButton icon="square-pen" label={tr("Nieuwe sessie", "New session")} onclick={newSession} />
        {/snippet}
      </PanelHeader>
    </div>
    <div class="top">
      <ConnectionLine {view} />
      {#if view.sessions.length > SHOWN}<SearchField bind:value={query} placeholder={tr("Zoek sessies", "Search sessions")} />{/if}
      {#if query.trim() && !all.length}<p class="none">{tr("Geen sessie gevonden.", "No session matches.")}</p>{/if}
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

    {#if !view.sessions.length && view.phase === "connected"}
      <EmptyState icon="layers" title={tr("Geen sessies", "No sessions")} text={tr("Sessies van je coding-agents op je Mac verschijnen hier.", "Sessions of your coding agents on your Mac show up here.")} action={tr("Nieuwe sessie", "New session")} onaction={newSession} />
    {/if}
  </div>
</div>

{#if menu}<Menu sections={menuSections} anchor={menu.anchor} onclose={() => (menu = null)} />{/if}
{#if blocked}
  <div class="alert-scrim"><div class="alert"><p>{blocked}</p><button onclick={() => (blocked = null)}>OK</button></div></div>
{/if}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px; }
  .none { margin: 0; padding: 24px 0; text-align: center; font: var(--pt-body); color: var(--text2); }
  .more { width: calc(100% - 16px); margin: 0 8px; min-height: 40px; font: var(--pt-label) !important; color: var(--text2) !important; }
  .alert-scrim { position: fixed; inset: 0; z-index: 60; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; }
  .alert { width: 270px; background: rgba(37, 37, 37, 0.96); border-radius: 14px; overflow: hidden; text-align: center; }
  .alert p { margin: 0; padding: 20px 16px; font: var(--pt-control); }
  .alert button { width: 100%; height: 44px; border-top: 0.5px solid rgba(255, 255, 255, 0.12) !important; color: var(--blue) !important; font: 600 17px var(--font) !important; }
</style>
