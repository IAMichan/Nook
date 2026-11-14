<script lang="ts">
  // The Agents tab of the iPhone app: every session on the computer, what waits on you first, then what works, then
  // the eight most recent (Show more for the rest), a search once there are more than eight, and New session.
  import { groupSessions, has, matchesSession, may, Feature, type ClientView } from "../../lib/companion";
  import { tr } from "../../lib/i18n.svelte";
  import Icon from "../../components/Icon.svelte";
  import SessionRow from "./SessionRow.svelte";

  let { view, act, onopen, onnew }: {
    view: ClientView;
    act: (f: () => Promise<ClientView>) => Promise<void>;
    onopen: (id: string) => void;
    onnew: () => void;
  } = $props();

  let query = $state("");
  let more = $state(false);
  const RECENT = 8;

  const all = $derived(view.sessions.filter((s) => !query.trim() || matchesSession(s, query)));
  const groups = $derived(groupSessions(all));
  const rest = $derived(more || query.trim() ? groups.rest : groups.rest.slice(0, RECENT));
  const canStart = $derived(has(view, Feature.start) && may(view, "operate"));
  const canApprove = $derived(may(view, "approve"));
</script>

<div class="agents">
  <div class="bar">
    {#if view.sessions.length > RECENT}
      <label class="search">
        <Icon name="search" size={15} />
        <input bind:value={query} placeholder={tr("Zoek een sessie", "Find a session")} aria-label={tr("Zoek een sessie", "Find a session")} autocapitalize="off" />
      </label>
    {:else}
      <span class="spacer"></span>
    {/if}
    {#if canStart}
      <button class="primary new" onclick={onnew} aria-label={tr("Nieuwe sessie", "New session")}><Icon name="plus" size={16} /> {tr("Nieuw", "New")}</button>
    {/if}
  </div>
  <div class="list">
    {#if groups.waiting.length}
      <h3>{tr("Wacht op jou", "Waiting for you")}</h3>
      {#each groups.waiting as s (s.id)}<SessionRow session={s} {canApprove} onopen={() => onopen(s.id)} {act} />{/each}
    {/if}
    {#if groups.working.length}
      <h3>{tr("Aan het werk", "Working")}</h3>
      {#each groups.working as s (s.id)}<SessionRow session={s} {canApprove} onopen={() => onopen(s.id)} {act} />{/each}
    {/if}
    {#if rest.length}
      <h3>{tr("Recent", "Recent")}</h3>
      {#each rest as s (s.id)}<SessionRow session={s} {canApprove} onopen={() => onopen(s.id)} {act} />{/each}
      {#if !more && !query.trim() && groups.rest.length > RECENT}
        <button class="ghost more" onclick={() => (more = true)}>{tr("Toon meer ({n})", "Show more ({n})", { n: groups.rest.length - RECENT })}</button>
      {/if}
    {/if}
    {#if !all.length}
      <p class="faint pad">
        {#if query.trim()}{tr("Geen sessie die daarop lijkt.", "No session matches that.")}
        {:else if view.phase === "connected"}{tr("Geen sessies.", "No sessions.")}{/if}
      </p>
      {#if canStart && !query.trim() && view.phase === "connected"}
        <button class="start" onclick={onnew}>{tr("Start een sessie", "Start a session")}</button>
      {/if}
    {/if}
  </div>
</div>

<style>
  .agents { flex: 1; min-height: 0; display: flex; flex-direction: column; }
  .bar { display: flex; gap: var(--space-8); align-items: center; padding: var(--space-8) var(--space-12); }
  .spacer { flex: 1; }
  .search { flex: 1; display: flex; align-items: center; gap: var(--space-6); padding: 0 var(--space-12); min-height: 40px; border-radius: var(--radius-control); background: var(--field); border: 1px solid var(--field-stroke); color: var(--text3); }
  .search input { flex: 1; min-width: 0; border: none; background: transparent; padding: 0; min-height: 38px; }
  .new { min-height: 40px; display: inline-flex; align-items: center; gap: var(--space-4); }
  .list { flex: 1; overflow-y: auto; padding: 0 0 var(--space-24); }
  h3 { margin: var(--space-12) var(--space-16) var(--space-4); font: var(--text-label); color: var(--text2); text-transform: uppercase; letter-spacing: 0.04em; }
  .more { margin: var(--space-8) var(--space-16); min-height: 40px; }
  .start { margin: 0 var(--space-16); min-height: 46px; }
  .pad { padding: var(--space-16); margin: 0; }
</style>
