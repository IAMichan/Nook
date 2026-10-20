<script lang="ts">
  // The Filters button next to the pull request search (`PullRequestFilterMenu` on the Mac): a dropdown with the filter
  // kinds on the left (each with its current choice) and the choices of the kind you point at on the right. A badge
  // counts the choices that differ from the default; the panel stays open so several filters can be set in a row.
  import {
    activeCount, defaultFilter, draftNames, scopeNames, stateNames, statusNames,
    type DraftFilter, type PullRequestFilter, type ScopeFilter, type StateFilter, type StatusFilter,
  } from "../../../lib/pulls";

  let { filter = $bindable(), authors, watching = false }: { filter: PullRequestFilter; authors: string[]; watching?: boolean } = $props();

  type Kind = "state" | "involvement" | "author" | "draft" | "checks";
  const titles: Record<Kind, string> = { state: "Status", involvement: "Betrokkenheid", author: "Auteur", draft: "Concept", checks: "Checks" };
  let open = $state(false);
  let kind = $state<Kind>("state");
  let root = $state<HTMLElement | null>(null);
  const count = $derived(activeCount(filter));

  function value(k: Kind): string {
    switch (k) {
      case "state": return stateNames[filter.state];
      case "involvement": return scopeNames[filter.scope];
      case "author": return filter.author ? `@${filter.author}` : "Iedereen";
      case "draft": return draftNames[filter.draft];
      case "checks": return statusNames[filter.status];
    }
  }

  function isDefault(k: Kind): boolean {
    const d = defaultFilter();
    switch (k) {
      case "state": return filter.state === d.state;
      case "involvement": return filter.scope === d.scope;
      case "author": return filter.author === null;
      case "draft": return filter.draft === d.draft;
      case "checks": return filter.status === d.status;
    }
  }

  const stateTone: Record<StateFilter, string> = { all: "", open: "good", closed: "soft", merged: "merged" };
  const statusTone: Record<StatusFilter, string> = { any: "", failing: "bad", pending: "wait", passing: "good" };
  // Watched only shows while organizations or repositories are watched (or it is the current choice).
  const scopes = $derived((Object.keys(scopeNames) as ScopeFilter[]).filter((s) => s !== "watched" || watching || filter.scope === "watched"));

  function outside(e: MouseEvent) {
    if (open && root && !root.contains(e.target as Node)) open = false;
  }
</script>

<svelte:window onclick={outside} onkeydown={(e) => e.key === "Escape" && (open = false)} />

<div class="menu" bind:this={root}>
  <button class="trigger" class:active={count > 0} aria-expanded={open} title="Filters" onclick={() => (open = !open)}>
    <span aria-hidden="true">≡</span> Filters
    {#if count > 0}<span class="badge">{count}</span>{/if}
  </button>
  {#if open}
    <div class="panel" role="dialog" aria-label="Filters">
      <div class="kinds">
        {#each ["state", "involvement"] as const as k (k)}{@render kindRow(k)}{/each}
        <div class="divider"></div>
        {#each ["author", "draft", "checks"] as const as k (k)}{@render kindRow(k)}{/each}
        {#if count > 0}
          <div class="divider"></div>
          <button class="choice" onclick={() => (filter = defaultFilter(filter.query))}><span class="mark">↺</span>Filters wissen</button>
        {/if}
      </div>
      <div class="sep"></div>
      <div class="choices">
        <div class="header">{titles[kind]}</div>
        {#if kind === "state"}
          {#each Object.keys(stateNames) as StateFilter[] as s (s)}
            {@render choice(stateNames[s], filter.state === s, () => (filter.state = s), stateTone[s])}
          {/each}
        {:else if kind === "involvement"}
          {#each scopes as s (s)}{@render choice(scopeNames[s], filter.scope === s, () => (filter.scope = s))}{/each}
        {:else if kind === "author"}
          <div class="scroll">
            {@render choice("Iedereen", filter.author === null, () => (filter.author = null))}
            {#each authors as login (login)}{@render choice(`@${login}`, filter.author === login, () => (filter.author = login))}{/each}
          </div>
        {:else if kind === "draft"}
          {#each Object.keys(draftNames) as DraftFilter[] as d (d)}{@render choice(draftNames[d], filter.draft === d, () => (filter.draft = d))}{/each}
        {:else}
          {#each Object.keys(statusNames) as StatusFilter[] as s (s)}
            {@render choice(statusNames[s], filter.status === s, () => (filter.status = s), statusTone[s])}
          {/each}
        {/if}
      </div>
    </div>
  {/if}
</div>

{#snippet kindRow(k: Kind)}
  <!-- Pointing at a kind shows its choices, like a submenu. -->
  <button class="kind" class:on={kind === k} onclick={() => (kind = k)} onmouseenter={() => (kind = k)} onfocus={() => (kind = k)}>
    <span class="title">{titles[k]}</span>
    <span class="value" class:set={!isDefault(k)}>{value(k)}</span>
    <span class="faint">›</span>
  </button>
{/snippet}

{#snippet choice(title: string, chosen: boolean, pick: () => void, tone = "")}
  <button class="choice" class:on={chosen} aria-pressed={chosen} onclick={pick}>
    <span class="mark {tone}">●</span>{title}<span class="spacer"></span>{#if chosen}<span>✓</span>{/if}
  </button>
{/snippet}

<style>
  .menu { position: relative; flex: none; }
  .trigger { height: 30px; padding: 0 10px; display: flex; align-items: center; gap: 5px; color: var(--text2); background: var(--field); font-size: 12.5px; }
  .trigger.active, .trigger:hover { color: var(--paper); }
  .badge { min-width: 15px; height: 15px; border-radius: 8px; background: var(--paper); color: var(--ink); font-size: 10.5px; font-weight: 600; display: inline-grid; place-items: center; padding: 0 4px; }
  .panel { position: absolute; right: 0; top: 36px; z-index: 20; width: min(404px, calc(100vw - 32px)); display: flex; padding: 6px; background: var(--graphite); border: 1px solid var(--line2); border-radius: 12px; box-shadow: 0 12px 32px rgba(0, 0, 0, 0.5); }
  .kinds { width: 50%; max-width: 200px; display: flex; flex-direction: column; }
  .choices { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .sep { width: 1px; background: var(--line2); margin: 0 4px; }
  .divider { height: 1px; background: var(--line2); margin: 4px 6px; }
  .header { font-size: 11px; color: var(--text3); padding: 4px 8px 6px; }
  .scroll { max-height: 220px; overflow-y: auto; display: flex; flex-direction: column; }
  .kind, .choice { display: flex; align-items: center; gap: 8px; height: 28px; padding: 0 8px; border: none; background: none; border-radius: 7px; text-align: left; font-size: 12.5px; white-space: nowrap; }
  .kind:hover, .choice:hover { background: var(--smoke); }
  .kind.on, .choice.on { background: var(--smoke); }
  .title { flex: 1; overflow: hidden; text-overflow: ellipsis; }
  .value { font-size: 11px; color: var(--text3); overflow: hidden; text-overflow: ellipsis; }
  .value.set { color: var(--paper); }
  .spacer { flex: 1; }
  .mark { font-size: 8px; color: var(--text3); width: 12px; text-align: center; }
  .mark.good { color: var(--mint); }
  .mark.bad { color: var(--coral); }
  .mark.soft { color: var(--coral); opacity: 0.8; }
  .mark.wait { color: var(--amber); }
  .mark.merged { color: var(--violet); }
</style>
