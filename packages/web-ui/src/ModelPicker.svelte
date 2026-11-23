<script lang="ts" module>
  /** One model in the menu: its id (what the surface sends back), its name, and the agent or place it belongs to. */
  export interface ModelChoice {
    id: string;
    title: string;
    group: string;
    chosen?: boolean;
    /** A model on this Mac: its place shows a laptop and comes first in the rail. */
    local?: boolean;
  }

  export interface ModelPickerTexts {
    /** The chip's tooltip ("Choose the model Nook thinks with"). */
    button: string;
    search: string;
    /** No model matches the search, or there is none at all. */
    empty: string;
  }
</script>

<script lang="ts">
  // The model chip in the composer's row and its panel, as on the Mac (`BrainChip`, `ModelPicker`, `RailDropdown`):
  // the chip shows the agent's logo and "Agent · Model"; the panel above it has a rail of places on the left (this
  // Mac's models first, then one logo per agent) and the shown place's column on the right: its name, a search field and
  // its models, each with its maker's mark, the chosen one with a faint fill. ↑/↓ move over the models while the search
  // keeps the keyboard and Return picks. Colors come from the surface as the composer's `--nc-*` variables.
  import AgentMark from "./AgentMark.svelte";
  import { brandFor } from "./brands";

  let {
    label,
    group = "",
    choices,
    texts,
    onchoose,
    onopen,
    disabled = false,
  }: {
    label: string;
    group?: string;
    choices: readonly ModelChoice[];
    texts: ModelPickerTexts;
    onchoose: (id: string) => void;
    /** The menu opens: the surface can fetch the newest list. */
    onopen?: () => void;
    disabled?: boolean;
  } = $props();

  /** The panel's width on the Mac (`ModelPickerStyle.width`), and the room it keeps from the window's edges. */
  const width = 340;
  const margin = 12;

  let open = $state(false);
  let query = $state("");
  let highlight = $state(0);
  /** The place looked at; null is the place in use. */
  let shownPlace = $state<string | null>(null);
  /** How far the panel moves left or right of the chip to stay inside the window. */
  let shift = $state(-4);
  let root = $state<HTMLDivElement>();
  let search = $state<HTMLInputElement>();
  let list = $state<HTMLDivElement>();

  const chosen = $derived(choices.find((c) => c.chosen));

  /** The places in the rail: this Mac first, then the agents in the order Nook lists them. */
  const places = $derived.by(() => {
    const out: { name: string; local: boolean }[] = [];
    for (const choice of choices) {
      if (!out.some((p) => p.name === choice.group)) out.push({ name: choice.group, local: !!choice.local });
    }
    return [...out.filter((p) => p.local), ...out.filter((p) => !p.local)];
  });
  const inUse = $derived(chosen?.group ?? places.find((p) => p.name === group)?.name ?? places[0]?.name ?? "");
  const current = $derived(places.find((p) => p.name === (shownPlace ?? inUse)) ?? places[0]);

  const rows = $derived.by(() => {
    if (!current) return [];
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return choices.filter((c) => c.group === current.name && words.every((w) => c.title.toLowerCase().includes(w)));
  });
  const active = $derived(rows.length ? Math.min(highlight, rows.length - 1) : -1);

  /** The chip's mark: the agent's logo, or the local model's maker (a laptop when it has none). */
  const chipLocal = $derived(!!chosen?.local && !brandFor(label));
  const chipMark = $derived(chosen?.local ? label : group || label);

  function place() {
    const rect = root?.getBoundingClientRect();
    if (!rect) return;
    const room = window.innerWidth - margin;
    const panel = Math.min(width, window.innerWidth - 2 * margin);
    shift = Math.max(margin - rect.left, Math.min(-4, room - panel - rect.left));
  }

  function toggle() {
    open = !open;
    query = "";
    highlight = 0;
    shownPlace = null;
    if (open) {
      onopen?.();
      place();
      queueMicrotask(() => search?.focus());
    }
  }

  function show(name: string) {
    shownPlace = name;
    query = "";
    highlight = 0;
    search?.focus();
  }

  function choose(choice: ModelChoice | undefined) {
    if (!choice) return;
    open = false;
    if (!choice.chosen) onchoose(choice.id);
  }

  function step(by: number) {
    if (!rows.length) return;
    highlight = (active + by + rows.length) % rows.length;
    queueMicrotask(() => list?.querySelector<HTMLElement>(`[data-index="${highlight}"]`)?.scrollIntoView({ block: "nearest" }));
  }

  function key(e: KeyboardEvent) {
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    if (e.key === "ArrowDown") step(1);
    else if (e.key === "ArrowUp") step(-1);
    else if (e.key === "Enter") choose(rows[active]);
    else return;
    e.preventDefault();
  }
</script>

<svelte:window
  onclick={(e) => open && !root?.contains(e.target as Node) && (open = false)}
  onkeydown={(e) => open && e.key === "Escape" && ((open = false), e.stopPropagation())}
  onresize={() => open && place()}
/>

<div class="mp" bind:this={root}>
  <button type="button" class="mp-chip" class:open onclick={toggle} title={texts.button} aria-haspopup="dialog" aria-expanded={open} {disabled}>
    <AgentMark name={chipMark} local={chipLocal} letter={!chosen?.local} size={15} />
    <span class="mp-label">{group ? `${group} · ${label}` : label}</span>
    <svg class="mp-chevron" viewBox="0 0 16 16" aria-hidden="true"><path d="m4.5 6.5 3.5 3.5 3.5-3.5" /></svg>
  </button>
  {#if open}
    <div class="mp-panel" role="dialog" aria-label={texts.button} style:left="{shift}px" style:width="min({width}px, calc(100vw - {2 * margin}px))">
      <div class="mp-rail">
        {#each places as p, i (p.name)}
          {#if i > 0 && places[i - 1].local && !p.local}<span class="mp-rail-line" aria-hidden="true"></span>{/if}
          <button type="button" class="mp-place" class:shown={p === current} title={p.name} aria-label={p.name} aria-pressed={p === current} onclick={() => show(p.name)}>
            <AgentMark name={p.name} local={p.local} letter size={18} />
            {#if p.name === inUse && p !== current}<span class="mp-in-use" aria-hidden="true"></span>{/if}
          </button>
        {/each}
      </div>
      <div class="mp-column">
        {#if current}<div class="mp-header">{current.name}</div>{/if}
        <label class="mp-search">
          <svg viewBox="0 0 16 16" aria-hidden="true"><circle cx="7" cy="7" r="4.5" /><path d="m10.5 10.5 3 3" /></svg>
          <input type="search" bind:this={search} bind:value={query} oninput={() => (highlight = 0)} onkeydown={key}
                 placeholder={texts.search} aria-label={texts.search} />
        </label>
        <div class="mp-list" role="listbox" aria-label={current?.name} bind:this={list}>
          {#each rows as choice, index (choice.id)}
            <button type="button" class="mp-row" class:chosen={choice.chosen} class:active={index === active} data-index={index}
                    role="option" aria-selected={!!choice.chosen} onmouseenter={() => (highlight = index)} onclick={() => choose(choice)}>
              <AgentMark name={choice.local ? choice.title : brandFor(choice.title) ? choice.title : choice.group} size={14} />
              <span class="mp-title">{choice.title}</span>
            </button>
          {:else}
            <p class="mp-empty">{texts.empty}</p>
          {/each}
        </div>
      </div>
    </div>
  {/if}
</div>

<style>
  /* Class names start with mp-: the surface's own stylesheet (the extension's side panel) has its own .menu, .empty… */
  .mp { position: relative; min-width: 0; }
  .mp button { margin: 0; border: 0; font-family: inherit; font-weight: inherit; line-height: inherit; cursor: pointer; transition: background-color 0.15s ease, color 0.15s ease; }
  .mp-chip {
    display: flex;
    align-items: center;
    gap: 6px;
    max-width: 100%;
    min-width: 0;
    height: 28px;
    padding: 0 8px;
    border-radius: var(--nc-control-radius, 8px);
    background: transparent;
    color: var(--nc-faint, #62626c);
    font-size: 13px;
    white-space: nowrap;
  }
  .mp-chip:hover:not(:disabled), .mp-chip.open { background: var(--nc-hover, #f4f4f5); color: var(--nc-text, #27272a); }
  .mp-chip:disabled { cursor: default; opacity: 0.6; }
  .mp-chip:focus-visible { outline: 2px solid var(--nc-accent, #1e1e22); outline-offset: 2px; }
  .mp-label { overflow: hidden; text-overflow: ellipsis; min-width: 0; }
  .mp-chevron { flex-shrink: 0; width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }

  .mp-panel {
    position: absolute;
    bottom: calc(100% + 8px);
    z-index: 20;
    display: flex;
    align-items: stretch;
    padding: 4px;
    border: 1px solid var(--nc-line, #e4e4e7);
    border-radius: var(--nc-menu-radius, 12px);
    background: var(--nc-menu, var(--nc-surface, #ffffff));
    color: var(--nc-text, #27272a);
    box-shadow: 0 12px 32px rgb(0 0 0 / 0.28);
    overflow: hidden;
  }

  .mp-rail {
    flex-shrink: 0;
    display: flex;
    flex-direction: column;
    gap: 4px;
    width: 44px;
    padding: 6px;
    background: color-mix(in srgb, var(--nc-text, #27272a) 3%, transparent);
    border-right: 1px solid var(--nc-line, #e4e4e7);
  }
  .mp-rail-line { align-self: center; width: 18px; height: 1px; margin: 2px 0; background: var(--nc-line-focus, #d4d4d8); }
  .mp-place {
    position: relative;
    display: grid;
    place-items: center;
    width: 32px;
    height: 32px;
    padding: 0;
    border-radius: var(--nc-control-radius, 8px);
    background: transparent;
    color: var(--nc-text, #27272a);
  }
  .mp-place:hover { background: var(--nc-hover, #f4f4f5); }
  .mp-place.shown { background: color-mix(in srgb, var(--nc-text, #27272a) 8%, transparent); }
  .mp-place:focus-visible { outline: 2px solid var(--nc-accent, #1e1e22); outline-offset: -2px; }
  .mp-in-use {
    position: absolute;
    top: 4px;
    right: 4px;
    width: 4px;
    height: 4px;
    border-radius: 50%;
    background: color-mix(in srgb, var(--nc-text, #27272a) 70%, transparent);
  }

  .mp-column { flex: 1; min-width: 0; display: flex; flex-direction: column; padding: 0 4px; }
  .mp-header { padding: 8px 8px 4px; color: var(--nc-faint, #62626c); font-size: 11.5px; font-weight: 500; }
  .mp-search {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 8px;
    border-bottom: 1px solid var(--nc-line, #e4e4e7);
    color: var(--nc-faint, #62626c);
  }
  .mp-search svg { flex-shrink: 0; width: 13px; height: 13px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; }
  .mp-search input {
    flex: 1;
    min-width: 0;
    margin: 0;
    padding: 0;
    border: 0;
    background: transparent;
    color: var(--nc-text, #27272a);
    font: inherit;
    font-size: 13px;
    outline: none;
  }
  .mp-search input::placeholder { color: var(--nc-faint, #62626c); }
  .mp-search input::-webkit-search-cancel-button { display: none; }

  .mp-list { max-height: 240px; overflow-y: auto; padding: 4px 0; }
  .mp-row {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    min-height: 30px;
    padding: 6px 8px;
    border-radius: var(--nc-chip-radius, 6px);
    background: transparent;
    color: var(--nc-text, #27272a);
    font-size: 13px;
    text-align: left;
  }
  .mp-row.chosen { background: color-mix(in srgb, var(--nc-text, #27272a) 8%, transparent); }
  .mp-row.active { background: var(--nc-hover, #f4f4f5); }
  .mp-row:focus-visible { outline: 2px solid var(--nc-accent, #1e1e22); outline-offset: -2px; }
  .mp-title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .mp-empty { margin: 0; padding: 10px; color: var(--nc-faint, #62626c); font-size: 12px; }
</style>
