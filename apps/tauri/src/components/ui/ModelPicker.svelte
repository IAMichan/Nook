<script lang="ts">
  // The one model picker (`ModelPicker`): a rail of places on the left (this computer's models first and set apart,
  // then choices across agents such as "Auto", then one logo per agent or service, once per account) with a "+" at its
  // foot that opens Settings, and the shown place's column on the right: its name, an optional line, rows above the
  // search, the search, the models (logo, star, a reason in its tooltip when one cannot be picked) and actions. ↑/↓ move over the rows
  // while the search keeps the keys, Return picks, Ctrl+1…9 pick the nth model. Used for the agents' models and Nook's
  // own brain alike; callers hand over places and a list per place and never build a second model menu.
  import { untrack, type Snippet } from "svelte";
  import { tr } from "../../lib/i18n.svelte";
  import {
    MODEL_PICKER, clampHighlight, numberKeyRow, placeHelp, railGroups, stepHighlight,
    type ModelPickerItem, type ModelPickerList, type ModelPickerPlace,
  } from "../../lib/model-picker";
  import AgentMark from "./AgentMark.svelte";
  import Ico from "./Ico.svelte";
  import { tip } from "./tip";

  let {
    places, chosen, addHelp, onsettings, list, above, footer, trailing, onclose,
  }: {
    places: ModelPickerPlace[];
    /** The id of the place in use; the panel opens on it. */
    chosen: string;
    /** What the "+" at the foot of the rail says it adds. */
    addHelp: string;
    /** Opens the Settings page where places and models are set up; the "+" goes there. */
    onsettings: () => void;
    /** The rows for a place and the search text. */
    list: (place: ModelPickerPlace, query: string) => ModelPickerList;
    /** Rows above the search for a place. */
    above?: Snippet<[ModelPickerPlace]>;
    /** Under the rail and the column: what is chosen beside the model (access, effort). */
    footer?: Snippet;
    /** A column right of the models (the reasoning levels). */
    trailing?: Snippet;
    /** Closes the panel after a pick. */
    onclose: () => void;
  } = $props();

  // The panel opens on the place in use; after that the rail decides what is shown.
  let shownId = $state(untrack(() => chosen));
  let query = $state("");
  let highlight = $state(0);
  let listEl = $state<HTMLDivElement>();

  const shown = $derived(places.find((p) => p.id === shownId) ?? places[0]);
  const content = $derived(shown ? list(shown, query) : { models: [] });
  const rows = $derived([...content.models, ...(content.actions ?? [])]);
  const current = $derived(clampHighlight(highlight, rows.map((r) => !r.disabledReason)));

  function show(place: ModelPickerPlace) {
    shownId = place.id;
    query = "";
    highlight = 0;
  }

  function pick(items: ModelPickerItem[], index: number | null) {
    if (index === null || !items[index] || items[index].disabledReason) return;
    items[index].pick();
    if (!items[index].staysOpen) onclose();
  }

  function keys(e: KeyboardEvent) {
    if (e.altKey || e.metaKey) return;
    const enabled = rows.map((r) => !r.disabledReason);
    if (e.ctrlKey && /^[1-9]$/.test(e.key)) {
      const row = numberKeyRow(Number(e.key), content.models.map((m) => !m.disabledReason));
      if (row !== null) { e.preventDefault(); pick(content.models, row); }
      return;
    }
    if (e.ctrlKey) return;
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault();
      highlight = stepHighlight(current, e.key === "ArrowDown" ? 1 : -1, enabled) ?? highlight;
      queueMicrotask(() => listEl?.querySelector(".row.lit")?.scrollIntoView({ block: "nearest" }));
    } else if (e.key === "Enter") {
      e.preventDefault();
      pick(rows, current);
    }
  }

  const focusNow = (node: HTMLInputElement) => { queueMicrotask(() => node.focus()); };
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="model-picker" onkeydown={keys}>
  <div class="body">
    <nav class="rail" aria-label={tr("Plekken", "Places")}>
      {#each railGroups(places) as group, g (g)}
        {#if g > 0}<span class="sep" aria-hidden="true"></span>{/if}
        {#each group as place (place.id)}
          <button type="button" class="place" class:on={place.id === shown?.id} aria-pressed={place.id === shown?.id} use:tip={placeHelp(place)} onclick={() => show(place)}>
            {#if place.isLocal}
              <Ico name="laptop" size={14} stroke={2} />
            {:else if place.icon}
              <Ico name={place.icon} size={14} stroke={2} />
            {:else}
              <AgentMark agent={place.name} size={MODEL_PICKER.markSize} />
            {/if}
            {#if place.account}<span class="badge">{place.account}</span>{/if}
          </button>
        {/each}
      {/each}
      <span class="grow"></span>
      <button type="button" class="place add" use:tip={addHelp} onclick={() => { onclose(); onsettings(); }}><Ico name="plus" size={13} stroke={2} /></button>
    </nav>
    {#if shown}
      <div class="column">
        <div class="title">{shown.name}</div>
        {#if shown.detail}<div class="detail">{shown.detail}</div>{/if}
        {@render above?.(shown)}
        {#if !shown.icon}
          <label class="search">
            <Ico name="search" size={12} stroke={2.2} />
            <input bind:value={query} placeholder={tr("Zoek modellen…", "Search models…")} aria-label={tr("Zoek modellen…", "Search models…")} autocomplete="off" use:focusNow oninput={() => (highlight = 0)} />
          </label>
        {/if}
        <div class="list" bind:this={listEl} role="listbox" aria-label={shown.name} style:max-height="{MODEL_PICKER.listHeight}px">
          {#each rows as item, i (item.id)}
            <div class="row" class:lit={i === current} class:chosen={item.chosen} class:disabled={!!item.disabledReason}
              role="option" aria-selected={!!item.chosen} aria-disabled={!!item.disabledReason} tabindex="-1"
              use:tip={item.disabledReason ?? ""} onmouseenter={() => !item.disabledReason && (highlight = i)} onclick={() => pick(rows, i)} onkeydown={() => {}}>
              {#if item.icon}<span class="mark"><Ico name={item.icon} size={13} stroke={2} /></span>
              {:else if item.brand}<span class="mark"><AgentMark agent={item.brand} size={16} /></span>{/if}
              <span class="text">
                <span class="name">{item.title}</span>
                {#if item.detail}<span class="sub">{item.detail}</span>{/if}
              </span>
              {#if item.trailing}<span class="trail">{item.trailing}</span>{/if}
              {#if item.favorite !== undefined}
                <button type="button" class="star" class:on={item.favorite} aria-pressed={item.favorite} use:tip={item.favorite ? tr("Geen favoriet meer", "Remove from favorites") : tr("Favoriet", "Favorite")}
                  onclick={(e) => { e.stopPropagation(); item.onfavorite?.(!item.favorite); }}><Ico name="star" size={12} stroke={2} fill={item.favorite ? "currentColor" : "none"} /></button>
              {/if}
            </div>
          {:else}
            <p class="empty">{content.emptyNote ?? tr("Geen modellen gevonden", "No models found")}</p>
          {/each}
        </div>
      </div>
    {/if}
    {#if trailing}<div class="side" style:width="{MODEL_PICKER.sideWidth}px">{@render trailing()}</div>{/if}
  </div>
  {#if footer}<div class="footer">{@render footer()}</div>{/if}
</div>

<style>
  .model-picker { display: flex; flex-direction: column; background: var(--menu); }
  .body { display: flex; align-items: stretch; min-height: 0; }
  .rail { display: flex; flex-direction: column; align-items: center; gap: var(--space-2); padding: var(--space-6) var(--space-4); border-right: 1px solid var(--line); }
  .sep { width: 18px; height: 1px; margin: var(--space-4) 0; background: var(--line2); }
  .grow { flex: 1; }
  .place { position: relative; display: grid; place-items: center; width: 32px; height: 32px; padding: 0; border: none; border-radius: var(--radius-control); background: none; color: var(--paper); }
  .place:hover:not(:disabled) { background: var(--smoke); }
  .place.on, .place.on:hover:not(:disabled) { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .place.add { color: var(--text3); }
  .badge { position: absolute; right: 1px; bottom: 1px; min-width: 12px; height: 12px; padding: 0 2px; border-radius: var(--radius-pill); background: var(--smoke); border: 1px solid var(--menu); color: var(--text2); font: var(--text-caption); line-height: 10px; text-align: center; }
  .column { flex: 1; min-width: 0; display: flex; flex-direction: column; padding: var(--space-6); }
  .title { padding: var(--space-4) var(--space-8) var(--space-2); font: var(--text-label); color: var(--text3); }
  .detail { padding: 0 var(--space-8) var(--space-4); font: var(--text-detail); color: var(--text3); }
  /* The search is a plain line in the panel (DropdownSearch), no field box. */
  .search { display: flex; align-items: center; gap: var(--space-6); margin: 0 0 var(--space-4); padding: 0 var(--space-8); height: 28px; color: var(--text3); }
  .search input { flex: 1; min-width: 0; height: 100%; padding: 0; border: none !important; background: none; box-shadow: none !important; font: var(--text-control); font-weight: 400; }
  .list { overflow-y: auto; display: flex; flex-direction: column; gap: 1px; }
  .row { display: flex; align-items: flex-start; gap: var(--space-8); min-height: 30px; padding: var(--space-6) var(--space-8); border-radius: var(--radius-chip); cursor: pointer; }
  .row.lit { background: var(--smoke); }
  /* The chosen model is shaded (DropdownStyle.chosen); there is no checkmark. */
  .row.chosen { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .row.chosen.lit { background: var(--smoke); }
  .row.disabled { cursor: default; opacity: 0.64; }
  .mark { display: grid; place-items: center; width: 16px; height: 21px; flex: none; color: var(--text2); }
  .text { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .name { font: var(--text-body); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .sub { font: var(--text-detail); color: var(--text3); }
  .trail { font: var(--text-detail); color: var(--text3); white-space: nowrap; line-height: 21px; }
  /* The star shows on a favorite, and on the row under the pointer or the keys to make one. */
  .star { display: grid; place-items: center; width: 18px; height: 18px; padding: 0; border: none; background: none; color: var(--text3); visibility: hidden; }
  .row:hover .star, .row.lit .star, .star.on { visibility: visible; }
  .star.on { color: var(--paper); }
  .star:hover:not(:disabled) { background: none; color: var(--paper); }
  .empty { margin: 0; padding: var(--space-12) var(--space-8); font: var(--text-detail); color: var(--text3); }
  .side { flex: none; border-left: 1px solid var(--line); }
  .footer { border-top: 1px solid var(--line); }
</style>
