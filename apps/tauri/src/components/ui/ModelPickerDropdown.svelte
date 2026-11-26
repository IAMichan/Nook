<script lang="ts">
  // The one model picker of Nook (`ModelPickerDropdown` / `ModelPicker` on the Mac): a rail of places on the left
  // (this computer's local models first, cross-agent choices like "Auto", then one logo per agent or service/account)
  // with a "+" at its foot that opens Settings, and on the right the shown place's column: its name, optional detail,
  // optional rows above the search, the search field, the models (favorite stars, trailing tags, actions), an optional
  // trailing column (thinking effort) and an optional footer (`ModelPickerOptions`). Both Nook's brain chip and the
  // coding-agent composers use this one component.
  import type { Snippet } from "svelte";
  import { tr } from "../../lib/i18n.svelte";
  import {
    clampedHighlight,
    groupPlaces,
    MODEL_PICKER_SIDE_WIDTH,
    MODEL_PICKER_WIDTH,
    numberKeyRow,
    placeHelp,
    stepHighlight,
    type ModelPickerItem,
    type ModelPickerList,
    type ModelPickerPlace,
  } from "../../lib/model-picker";
  import AgentMark from "../../views/companion/ui/AgentMark.svelte";
  import Dropdown from "./Dropdown.svelte";
  import DropdownRow from "./DropdownRow.svelte";
  import Ico from "./Ico.svelte";
  import { tip } from "./tip";

  let {
    open = $bindable(false),
    places,
    chosenId,
    list,
    addHelp,
    onadd,
    onopen,
    onplacechange,
    label,
    align = "left",
    below = false,
    hasSideColumn = false,
    trigger,
    above,
    trailing,
    footer,
  }: {
    open?: boolean;
    places: ModelPickerPlace[];
    /** The currently active place; the panel opens on it and marks it with a dot when another place is viewed. */
    chosenId: string;
    /** Rows to display for the shown place and search query. */
    list: (place: ModelPickerPlace, query: string) => ModelPickerList;
    /** Tooltip for the "+" button at the foot of the rail. */
    addHelp: string;
    /** Opens Settings to add a model, service, or agent. */
    onadd: () => void;
    onopen?: () => void;
    onplacechange?: (placeId: string) => void;
    label?: string;
    align?: "left" | "right";
    below?: boolean;
    /** Adds room for the 170 px trailing column beside the models (e.g. thinking effort). */
    hasSideColumn?: boolean;
    trigger: Snippet<[{ open: boolean; toggle: () => void }]>;
    above?: Snippet<[ModelPickerPlace]>;
    trailing?: Snippet;
    footer?: Snippet;
  } = $props();

  let shownId = $state("");
  let query = $state("");
  let highlight = $state(0);

  const railGroups = $derived(groupPlaces(places));
  const shown = $derived(places.find((p) => p.id === shownId) ?? places.find((p) => p.id === chosenId) ?? places[0]);
  const shownList = $derived<ModelPickerList>(shown ? list(shown, query) : { models: [] });
  const rows = $derived<ModelPickerItem[]>([...shownList.models, ...(shownList.actions ?? [])]);
  const enabled = $derived(rows.map((r) => !r.disabledReason));
  const current = $derived(clampedHighlight(highlight, enabled));
  const showSearch = $derived(!!shown && shown.searchable !== false && !shown.symbol);

  function handleOpen() {
    shownId = chosenId;
    query = "";
    highlight = 0;
    onplacechange?.(chosenId);
    onopen?.();
  }

  // Also reset when `open` is flipped programmatically (e.g. from Ctrl+Shift+M).
  let wasOpen = false;
  $effect(() => {
    if (open && !wasOpen) handleOpen();
    wasOpen = open;
  });

  function selectPlace(id: string) {
    shownId = id;
    query = "";
    highlight = 0;
    onplacechange?.(id);
  }

  function pickItem(item: ModelPickerItem | undefined) {
    if (!item || item.disabledReason) return;
    item.onpick();
    if (!item.staysOpen) open = false;
  }

  function handleKeyDown(e: KeyboardEvent) {
    if (!open) return;
    // Ctrl+1..9 (Cmd+1..9 on macOS) pick the nth enabled model row directly, matching `ModelPickerKeys`.
    if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key >= "1" && e.key <= "9") {
      const idx = numberKeyRow(Number(e.key), shownList.models.map((m) => !m.disabledReason));
      if (idx !== null) {
        e.preventDefault();
        e.stopPropagation();
        pickItem(shownList.models[idx]);
      }
      return;
    }
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      const next = stepHighlight(current, 1, enabled);
      if (next !== null) highlight = next;
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      const next = stepHighlight(current, -1, enabled);
      if (next !== null) highlight = next;
    } else if (e.key === "Enter" && current !== null) {
      e.preventDefault();
      pickItem(rows[current]);
    }
  }

  $effect(() => {
    if (!open) return;
    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  });

  function focusOnMount(node: HTMLInputElement) {
    node.focus();
  }
</script>

<Dropdown
  bind:open
  width={MODEL_PICKER_WIDTH + (hasSideColumn ? MODEL_PICKER_SIDE_WIDTH : 0)}
  {label}
  {align}
  {below}
  {trigger}
>
  {#snippet children()}
    <div class="picker" class:with-footer={!!footer}>
      <div class="rail">
        {#each railGroups as group, gi (gi)}
          {#if gi > 0}<span class="rail-line" aria-hidden="true"></span>{/if}
          {#each group as p (p.id)}
            <button
              type="button"
              class="place"
              class:on={p.id === shown?.id}
              class:dimmed={!!p.dimmed}
              onclick={() => selectPlace(p.id)}
              use:tip={placeHelp(p)}
              aria-label={placeHelp(p)}
              aria-pressed={p.id === shown?.id}
            >
              {#if p.isLocal}
                <Ico name="laptop" size={16} />
              {:else if p.symbol}
                <Ico name={p.symbol} size={15} />
              {:else}
                <AgentMark agent={p.name} size={18} />
              {/if}
              {#if p.id === chosenId && p.id !== shown?.id}
                <span class="dot" aria-hidden="true"></span>
              {/if}
            </button>
          {/each}
        {/each}
        <span class="rail-space"></span>
        <button
          type="button"
          class="place add"
          onclick={() => { open = false; onadd(); }}
          use:tip={addHelp}
          aria-label={tr("Toevoegen", "Add")}
        >
          <Ico name="plus" size={14} />
        </button>
      </div>
      <div class="column">
        {#if shown}
          <div class="dd-header">{shown.name}</div>
          {#if shown.detail}
            <p class="place-detail">{shown.detail}</p>
          {/if}
          {#if above}
            {@render above(shown)}
          {/if}
          {#if showSearch}
            <label class="search">
              <Ico name="search" size={14} />
              <input
                use:focusOnMount
                bind:value={query}
                oninput={() => (highlight = 0)}
                placeholder={tr("Zoek modellen…", "Search models…")}
                aria-label={tr("Zoek modellen", "Search models")}
              />
            </label>
          {/if}
          <div class="list">
            {#each rows as item, i (item.id)}
              <DropdownRow
                brand={item.brand}
                symbol={item.symbol}
                title={item.title}
                detail={item.detail}
                trailing={item.trailing}
                chosen={!!item.chosen}
                highlighted={current === i && (query.length > 0 || highlight > 0)}
                favorite={item.favorite}
                onstar={item.onstar}
                disabledReason={item.disabledReason}
                onclick={() => pickItem(item)}
              />
            {:else}
              <p class="empty">{shownList.emptyNote ?? tr("Geen modellen gevonden", "No models found")}</p>
            {/each}
          </div>
        {/if}
      </div>
      {#if hasSideColumn && trailing}
        <div class="side">
          {@render trailing()}
        </div>
      {/if}
    </div>
    {#if footer}
      <div class="footer">
        {@render footer()}
      </div>
    {/if}
  {/snippet}
</Dropdown>

<style>
  /* The panel's own padding goes: the rail runs to its edges, as `ModelPicker` draws it. */
  .picker { display: flex; align-items: stretch; margin: calc(-1 * var(--space-4)); min-height: 0; }
  .picker.with-footer { margin-bottom: 0; }
  .rail {
    display: flex; flex-direction: column; align-items: center; gap: var(--space-4); width: 44px; flex: none;
    padding: var(--space-6); background: color-mix(in srgb, var(--paper) 3%, transparent); border-right: 1px solid var(--line2);
  }
  .rail-line { width: 18px; height: 1px; margin: var(--space-2) 0; background: var(--line2); flex: none; }
  .rail-space { flex: 1; }
  .place {
    position: relative; display: grid; place-items: center; width: 32px; height: 32px; flex: none; padding: 0; margin: 0;
    border: 0; border-radius: var(--radius-control); background: transparent; color: var(--paper);
  }
  .place:hover { background: var(--smoke); }
  .place.on { background: color-mix(in srgb, var(--paper) 8%, transparent); }
  .place.dimmed { opacity: 0.5; }
  .place.add { color: var(--text3); }
  .dot { position: absolute; top: var(--space-4); right: var(--space-4); width: 4px; height: 4px; border-radius: 50%; background: color-mix(in srgb, var(--paper) 70%, transparent); }
  .column { display: flex; flex-direction: column; flex: 1; min-width: 0; padding: 0 var(--space-4) var(--space-4); }
  .place-detail { margin: 0; padding: 0 var(--space-8) var(--space-4); font: var(--text-detail); color: var(--text3); }
  .search { display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-8); border-bottom: 1px solid var(--line2); color: var(--text3); }
  .search input { flex: 1; min-width: 0; padding: 0; margin: 0; border: 0; outline: 0; background: transparent; font: var(--text-body); color: var(--paper); box-shadow: none; }
  .search input::placeholder { color: var(--text3); }
  .list { max-height: 240px; overflow-y: auto; padding: var(--space-4) 0; }
  .empty { margin: 0; padding: var(--space-8); font: var(--text-detail); color: var(--text3); }
  /* The effort column (`ModelPickerReasoning`), 170 pt beside the models behind a hairline. */
  .side { width: 170px; flex: none; display: flex; flex-direction: column; padding: 0 var(--space-4); border-left: 1px solid var(--line2); }
  .footer { margin: 0 calc(-1 * var(--space-4)) calc(-1 * var(--space-4)); padding: var(--space-6); border-top: 1px solid var(--line2); }
</style>
