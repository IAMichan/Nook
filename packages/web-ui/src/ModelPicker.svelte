<script lang="ts" module>
  /** One model in the menu: its id (what the surface sends back), its name, and the agent or place it belongs to. */
  export interface ModelChoice {
    id: string;
    title: string;
    group: string;
    chosen?: boolean;
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
  // The model chip in the composer's row, as on the Mac (`BrainChip`): the agent and model Nook thinks with, and a menu
  // above it with every model grouped per agent or place ("Claude Code", "On this Mac"), the chosen one ticked. A search
  // field shows once the list is long. Colors come from the surface as the composer's `--nc-*` variables.
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

  let open = $state(false);
  let query = $state("");
  let root = $state<HTMLDivElement>();
  let search = $state<HTMLInputElement>();

  const filtered = $derived.by(() => {
    const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    return choices.filter((c) => words.every((w) => `${c.title} ${c.group}`.toLowerCase().includes(w)));
  });
  const groups = $derived.by(() => {
    const out: { name: string; items: ModelChoice[] }[] = [];
    for (const choice of filtered) {
      let entry = out.find((g) => g.name === choice.group);
      if (!entry) out.push((entry = { name: choice.group, items: [] }));
      entry.items.push(choice);
    }
    return out;
  });

  function toggle() {
    open = !open;
    query = "";
    if (open) {
      onopen?.();
      queueMicrotask(() => search?.focus());
    }
  }

  function choose(choice: ModelChoice) {
    open = false;
    if (!choice.chosen) onchoose(choice.id);
  }
</script>

<svelte:window
  onclick={(e) => open && !root?.contains(e.target as Node) && (open = false)}
  onkeydown={(e) => open && e.key === "Escape" && ((open = false), e.stopPropagation())}
/>

<div class="model-picker" bind:this={root}>
  <button type="button" class="chip" class:open onclick={toggle} title={texts.button} aria-haspopup="menu" aria-expanded={open} {disabled}>
    {#if group}<span class="agent">{group}</span><span class="dot" aria-hidden="true">·</span>{/if}
    <span class="name">{label}</span>
    <svg viewBox="0 0 16 16" aria-hidden="true"><path d="m4.5 6.5 3.5 3.5 3.5-3.5" /></svg>
  </button>
  {#if open}
    <div class="menu" role="menu">
      {#if choices.length > 8}
        <input class="search" type="search" bind:this={search} bind:value={query} placeholder={texts.search} aria-label={texts.search} />
      {/if}
      <div class="list">
        {#each groups as g (g.name)}
          <div class="group">{g.name}</div>
          {#each g.items as choice (choice.id)}
            <button type="button" class="item" class:chosen={choice.chosen} role="menuitemradio" aria-checked={!!choice.chosen} onclick={() => choose(choice)}>
              <span class="title">{choice.title}</span>
              {#if choice.chosen}
                <svg viewBox="0 0 16 16" aria-hidden="true"><path d="m3.5 8.5 3 3 6-7" /></svg>
              {/if}
            </button>
          {/each}
        {:else}
          <p class="empty">{texts.empty}</p>
        {/each}
      </div>
    </div>
  {/if}
</div>

<style>
  .model-picker { position: relative; min-width: 0; }
  .chip {
    display: flex;
    align-items: center;
    gap: 4px;
    max-width: 100%;
    height: 28px;
    margin: 0;
    padding: 0 8px;
    border: 0;
    border-radius: var(--nc-control-radius, 8px);
    background: transparent;
    color: var(--nc-faint, #62626c);
    font: inherit;
    font-size: 12px;
    cursor: pointer;
    white-space: nowrap;
    min-width: 0;
  }
  .chip:hover:not(:disabled), .chip.open { background: var(--nc-hover, #f4f4f5); color: var(--nc-text, #27272a); }
  .chip:disabled { cursor: default; opacity: 0.6; }
  .chip:focus-visible { outline: 2px solid var(--nc-accent, #1e1e22); outline-offset: 2px; }
  .agent { flex-shrink: 0; }
  .dot { opacity: 0.6; }
  .name { overflow: hidden; text-overflow: ellipsis; color: var(--nc-text, #27272a); min-width: 0; }
  .chip svg { flex-shrink: 0; width: 12px; height: 12px; fill: none; stroke: currentColor; stroke-width: 1.6; stroke-linecap: round; stroke-linejoin: round; }
  .menu {
    position: absolute;
    left: -4px;
    bottom: calc(100% + 8px);
    z-index: 20;
    width: min(300px, calc(100vw - 32px));
    display: flex;
    flex-direction: column;
    padding: 6px;
    border: 1px solid var(--nc-line, #e4e4e7);
    border-radius: var(--nc-menu-radius, 12px);
    background: var(--nc-menu, var(--nc-surface, #ffffff));
    box-shadow: 0 12px 32px rgb(0 0 0 / 0.28);
  }
  .search {
    margin: 0 0 6px;
    padding: 6px 8px;
    border: 1px solid var(--nc-line, #e4e4e7);
    border-radius: var(--nc-control-radius, 8px);
    background: transparent;
    color: var(--nc-text, #27272a);
    font: inherit;
    font-size: 12px;
    outline: none;
  }
  .search:focus { border-color: var(--nc-line-focus, #d4d4d8); }
  .list { max-height: 320px; overflow-y: auto; }
  .group { padding: 8px 8px 4px; color: var(--nc-faint, #62626c); font-size: 11px; font-weight: 600; letter-spacing: 0.02em; }
  .item {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    margin: 0;
    padding: 6px 8px;
    border: 0;
    border-radius: var(--nc-control-radius, 8px);
    background: transparent;
    color: var(--nc-text, #27272a);
    font: inherit;
    font-size: 13px;
    text-align: left;
    cursor: pointer;
  }
  .item:hover, .item:focus-visible { background: var(--nc-hover, #f4f4f5); outline: none; }
  .title { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .item svg { flex-shrink: 0; width: 14px; height: 14px; fill: none; stroke: var(--nc-accent, #1e1e22); stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round; }
  .empty { margin: 0; padding: 10px 8px; color: var(--nc-faint, #62626c); font-size: 12px; }
</style>
