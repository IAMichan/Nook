<script lang="ts">
  // The Agents tab of the iPhone app (`SessionListView`): the header with Pull requests and New session, a card per
  // session that needs you, then the shelves Working and Recent (the first eight, then Show more), a search once there
  // are more than eight. Touch and hold a row for snooze, archive and end.
  import {
    companion, has, matchesSession, may, needsYouState, sortSessions, Feature,
    type ClientView, type SessionDigest,
  } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import { haptic } from "../../lib/haptics";
  import PanelHeader from "./ui/PanelHeader.svelte";
  import ConnectionLine from "./ui/ConnectionLine.svelte";
  import IconButton from "./ui/IconButton.svelte";
  import SearchField from "../../components/ui/SearchField.svelte";
  import SessionNotice from "./ui/SessionNotice.svelte";
  import ShelfHeader from "./ui/ShelfHeader.svelte";
  import AgentRow from "./ui/AgentRow.svelte";
  import EmptyState from "../../components/ui/EmptyState.svelte";
  import Menu, { type MenuItem } from "../../components/ui/Menu.svelte";
  import Sheet from "../../components/ui/Sheet.svelte";
  import PullRequests from "./PullRequests.svelte";
  import SnoozePicker from "./SnoozePicker.svelte";
  import WaitingRow from "./ui/WaitingRow.svelte";
  import SessionPrompt from "./SessionPrompt.svelte";
  import { placeOnPhone, ROW_MENU } from "../../lib/companion-sessions";
  import { sessionMenu } from "./session-menu";

  let { view, act, took, onorb, oncomputers, ongear, onopen, onnew, onelsewhere }: {
    view: ClientView;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    took: (v: ClientView) => void;
    onorb: (r: DOMRect) => void;
    /** The quick switcher under the title, with several computers paired. */
    oncomputers?: (r: DOMRect) => void;
    ongear: () => void;
    onopen: (id: string, digest?: SessionDigest) => void;
    onnew: () => void;
    /** A session on another paired computer: that computer becomes active and the session opens. */
    onelsewhere?: (mac: string, id: string, digest: SessionDigest) => void;
  } = $props();
  const queuedStarts = $derived((view.outbox ?? []).filter((q) => q.op === "start"));

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

  // The phone's shelves (`SessionShelf.onPhone`): what is at work, what waits on you, then the Mac's Pinned, the rest,
  // Snoozed and Settled. A computer without `agentsTab` pins, snoozes and settles nothing, so its sessions stay where
  // they were.
  let prompt = $state<{ kind: "rename" | "delete" | "end"; session: SessionDigest } | null>(null);
  const all = $derived(sortSessions(view.sessions).filter((s) => !query.trim() || matchesSession(s, query)));
  const shelves = $derived(placeOnPhone(all));
  const waiting = $derived(sortSessions(shelves.needsYou));
  const working = $derived(shelves.working);
  const recent = $derived(shelves.active);
  const shownRecent = $derived(more || query.trim() ? recent : recent.slice(0, SHOWN));

  function newSession() {
    if (!has(view, Feature.start)) return void (blocked = tr("Deze Mac kan nog geen sessies starten vanaf de telefoon. Werk Nook bij op je Mac.", "This Mac cannot start sessions from the phone yet. Update Nook on your Mac."));
    if (!may(view, "operate")) return void (blocked = tr("Sessies starten staat uit voor deze iPhone in Nook op je Mac.", "Starting sessions is turned off for this phone in Nook on your Mac."));
    haptic();
    onnew();
  }

  async function manage(session: SessionDigest, action: string, text?: string) {
    haptic();
    const r = await companion.call({ op: "manage", session: session.id, item: action, text });
    took(r.view);
    return r.response;
  }

  // The Mac's row menu, in its order (`ROW_MENU`).
  const menuSections = $derived.by<MenuItem[][]>(() => {
    if (!menu) return [];
    const s = menu.session;
    const offered = has(view, Feature.manage) && may(view, "operate") ? (s.actions ?? []) : [];
    return sessionMenu(ROW_MENU, s, offered, {
      run: (action) => void manage(s, action),
      ask: (kind) => (prompt = { kind, session: s }),
      pickTime: () => (picking = s),
      fork: async () => { const created = (await manage(s, "fork"))?.created; if (created) onopen(created); },
    });
  });
</script>

<div class="tab">
  <div class="scroll">
    <div bind:this={header}>
      <PanelHeader title={tr("Agents", "Agents")} {view} onorb={() => header && onorb((header.querySelector(".orb") as HTMLElement).getBoundingClientRect())} {oncomputers} {ongear}>
        {#snippet buttons()}
          {#if has(view, Feature.pullRequests) && may(view, "read")}<IconButton icon="git-pull-request" label={tr("Pull requests", "Pull requests")} onclick={() => { haptic(); pulls = true; }} />{/if}
          <IconButton icon="square-pen" label={tr("Nieuwe sessie", "New session")} onclick={newSession} />
        {/snippet}
      </PanelHeader>
    </div>
    <div class="top">
      <ConnectionLine {view} />
      {#if view.sessions.length > SHOWN || canHistory || has(view, Feature.agentsTab)}
        <div class="searchrow">
          <div class="grow"><SearchField bind:value={query} placeholder={tr("Zoek sessies", "Search sessions")} /></div>
        </div>
      {/if}
      {#if query.trim() && !all.length && !matches.length && !matchLoading}<p class="none">{tr("Geen sessie gevonden.", "No session matches.")}</p>{/if}
      {#each queuedStarts as q (q.id)}
        <WaitingRow icon="square-pen" title={q.text} detail={tr("Nieuwe sessie · wacht op je Mac", "New session · waiting for your Mac")} ondiscard={async () => took(await companion.discard(q.id))} />
      {/each}
    </div>
    {#if !working.length && !waiting.length && all.length && !query.trim()}
      <p class="calm"><span class="tick" aria-hidden="true">✓</span>{tr("Alles rustig. Er hoeft nu niets van je.", "All calm. Nothing needs you right now.")}</p>
    {/if}
    {#if working.length}
      <ShelfHeader title={tr("Aan het werk", "Working")} count={working.length} open={open.working ?? true} ontoggle={() => toggle("working")} />
      {#if open.working ?? true}
        {#each working as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id)} onhold={(r) => (menu = { session: s, anchor: r })} />{/each}
      {/if}
    {/if}
    {#if waiting.length}
      <h3 class="older on">{tr("Wacht op jou", "Waiting on you")}<span class="badge">{waiting.length}</span></h3>
      <div class="top">
        {#each waiting as s (s.id)}
          <SessionNotice {view} session={s} onopen={() => onopen(s.id)} {act} />
        {/each}
      </div>
    {/if}
    {#if shelves.pinned.length}
      <ShelfHeader title={tr("Vastgezet", "Pinned")} count={shelves.pinned.length} open={open.pinned ?? true} ontoggle={() => toggle("pinned")} />
      {#if open.pinned ?? true}
        {#each shelves.pinned as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id)} onhold={(r) => (menu = { session: s, anchor: r })} />{/each}
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

    {#if shelves.snoozed.length}
      <ShelfHeader title={tr("Gesnoozed", "Snoozed")} count={shelves.snoozed.length} open={open.snoozed ?? true} ontoggle={() => toggle("snoozed")} />
      {#if open.snoozed ?? true}
        {#each shelves.snoozed as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id)} onhold={(r) => (menu = { session: s, anchor: r })} />{/each}
      {/if}
    {/if}
    {#if shelves.settled.length}
      <ShelfHeader title={tr("Afgerond", "Settled")} count={shelves.settled.length} open={open.settled ?? false} ontoggle={() => { haptic(); open.settled = !(open.settled ?? false); try { localStorage.setItem("companion.shelves", JSON.stringify(open)); } catch { /* remembered for this visit */ } }} />
      {#if open.settled ?? false}
        {#each shelves.settled as s (s.id)}<AgentRow session={s} onopen={() => onopen(s.id)} onhold={(r) => (menu = { session: s, anchor: r })} />{/each}
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

    {#each view.others ?? [] as other (other.id)}
      {@const needy = other.sessions.filter((x) => x.items.length > 0 || needsYouState(x.attention)).length}
      <h3 class="older on">{tr("Op {mac}", "On {mac}", { mac: other.name })}{#if needy}<span class="badge">{needy}</span>{/if}{#if !other.reachable}<span class="away">· {tr("niet bereikbaar", "not reachable")}</span>{/if}</h3>
      {#each sortSessions(other.sessions).slice(0, 10) as s (s.id)}<AgentRow session={s} onopen={() => onelsewhere?.(other.id, s.id, s)} />{/each}
    {/each}

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
{#if prompt}
  {@const p = prompt}
  <SessionPrompt kind={p.kind} session={p.session} onclose={() => (prompt = null)} onrun={(action, text) => void manage(p.session, action, text)} />
{/if}
{#if blocked}
  <div class="alert-scrim"><div class="alert"><p>{blocked}</p><button onclick={() => (blocked = null)}>OK</button></div></div>
{/if}

<style>
  .tab { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .scroll { flex: 1; overflow-y: auto; padding-bottom: 24px; }
  .top { display: flex; flex-direction: column; gap: 12px; padding: 0 16px; }
  .searchrow { display: flex; align-items: center; gap: 6px; }
  .grow { flex: 1; min-width: 0; }
  .calm { margin: 0; padding: 12px 20px 0; display: flex; align-items: center; gap: 8px; font: var(--pt-body); color: var(--text2); }
  .tick { display: inline-flex; align-items: center; justify-content: center; width: 16px; height: 16px; border-radius: 50%; background: var(--mint); color: var(--canvas); font: 700 10px var(--font); }
  .none { margin: 0; padding: 24px 0; text-align: center; font: var(--pt-body); color: var(--text2); }
  .on { display: flex; align-items: center; gap: 6px; }
  .badge { min-width: 16px; height: 16px; padding: 0 4px; border-radius: 6px; background: rgba(240, 182, 90, 0.14); color: var(--amber); font: 600 11.4px ui-rounded, var(--font); display: inline-flex; align-items: center; justify-content: center; }
  .away { font: var(--pt-caption); color: var(--text3); }
  .older { margin: 0; padding: 16px 20px 4px; font: var(--pt-label); color: var(--text3); }
  .mini { display: inline-block; width: 12px; height: 12px; border-radius: 50%; border: 2px solid var(--text3); border-top-color: transparent; animation: spin 0.8s linear infinite; }
  @keyframes spin { to { transform: rotate(360deg); } }
  .more { width: calc(100% - 16px); margin: 0 8px; min-height: 40px; font: var(--pt-label) !important; color: var(--text2) !important; }
  .alert-scrim { position: fixed; inset: 0; z-index: 60; background: rgba(0, 0, 0, 0.45); display: flex; align-items: center; justify-content: center; }
  .alert { width: 270px; background: rgba(37, 37, 37, 0.96); border-radius: 14px; overflow: hidden; text-align: center; }
  .alert p { margin: 0; padding: 20px 16px; font: var(--pt-control); }
  .alert button { width: 100%; height: 44px; border-top: 0.5px solid rgba(255, 255, 255, 0.12) !important; color: var(--blue) !important; font: 600 17px var(--font) !important; }
</style>
