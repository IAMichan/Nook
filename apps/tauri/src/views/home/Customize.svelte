<script lang="ts">
  // Customize Home: what the greeting calls you, which features are your essentials, and in what order. Every change
  // is saved in Settings at once, so Home looks the same after a restart.
  import { untrack } from "svelte";
  import { fade, fly } from "svelte/transition";
  import { flip } from "svelte/animate";
  import { cubicOut } from "svelte/easing";
  import Icon from "../../components/Icon.svelte";
  import { moveTo, type Feature } from "../../lib/features";
  import { nook } from "../../lib/state.svelte";
  import { tr } from "../../lib/i18n.svelte";

  let { features, pinned, onclose }: { features: Feature[]; pinned: Feature[]; onclose: () => void } = $props();

  // The sheet edits its own copy, seeded once from what Home shows.
  let order = $state(untrack(() => pinned.map((f) => f.id)));
  let name = $state(nook.settings?.userName ?? "");
  let dragging = $state<string | null>(null);
  let list = $state<HTMLElement | null>(null);

  const byId = $derived(new Map(features.map((f) => [f.id, f])));
  const chosen = $derived(order.flatMap((id) => byId.get(id) ?? []));
  const others = $derived(features.filter((f) => !order.includes(f.id)));

  const save = () => nook.saveSettings({ homeEssentials: [...order] });
  const saveName = () => name.trim() !== (nook.settings?.userName ?? "") && nook.saveSettings({ userName: name.trim() });

  function add(id: string) {
    order = [...order, id];
    save();
  }

  function remove(id: string) {
    order = order.filter((x) => x !== id);
    save();
  }

  // Dragging uses pointer events: the webview keeps HTML drag and drop for files.
  function grab(e: PointerEvent, id: string) {
    dragging = id;
    (e.currentTarget as Element).setPointerCapture(e.pointerId);
  }

  function drag(e: PointerEvent) {
    if (!dragging || !list) return;
    const rows = [...list.querySelectorAll<HTMLElement>("[data-id]")].filter((r) => r.dataset.id !== dragging);
    const index = rows.filter((r) => {
      const box = r.getBoundingClientRect();
      return box.top + box.height / 2 < e.clientY;
    }).length;
    const next = moveTo(order, dragging, index);
    if (next.join() !== order.join()) order = next;
  }

  function drop() {
    if (!dragging) return;
    dragging = null;
    save();
  }

  function nudge(e: KeyboardEvent, id: string) {
    const step = e.key === "ArrowUp" ? -1 : e.key === "ArrowDown" ? 1 : 0;
    if (!step) return;
    e.preventDefault();
    order = moveTo(order, id, order.indexOf(id) + step);
    save();
    requestAnimationFrame(() => list?.querySelector<HTMLElement>(`[data-id="${id}"] .grip`)?.focus());
  }

  function keys(e: KeyboardEvent) {
    if (e.key === "Escape") onclose();
  }
</script>

<svelte:window onkeydown={keys} />

<div class="backdrop" role="presentation" transition:fade={{ duration: 160 }} onclick={(e) => e.target === e.currentTarget && onclose()}>
  <div class="sheet" role="dialog" aria-modal="true" aria-label={tr("Home aanpassen", "Customize Home")} in:fly={{ y: 12, duration: 240, easing: cubicOut }}>
    <header>
      <div><h3>{tr("Home aanpassen", "Customize Home")}</h3><p class="faint">{tr("Kies wat voor jou belangrijk is. Sleep om de volgorde te wijzigen.", "Choose what matters to you. Drag to reorder.")}</p></div>
      <button class="ghost close" onclick={onclose} aria-label={tr("Sluiten", "Close")}><Icon name="x" size={16} /></button>
    </header>

    <div class="body">
      <label class="name">
        <span>{tr("Hoe mag Nook je noemen?", "What should Nook call you?")}</span>
        <input bind:value={name} placeholder={tr("Je voornaam", "Your first name")} maxlength="40" onblur={saveName} onkeydown={(e) => e.key === "Enter" && saveName()} />
      </label>

      <h4>{tr("Je essentials", "Your essentials")}</h4>
      {#if chosen.length}
        <ul class="rows" bind:this={list}>
          {#each chosen as feature (feature.id)}
            <li class="row" class:dragging={dragging === feature.id} data-id={feature.id} animate:flip={{ duration: 200, easing: cubicOut }}>
              <button class="ghost grip" title={tr("Slepen om te verplaatsen", "Drag to reorder")} aria-label={tr(`${feature.title[0]} verplaatsen met de pijltjestoetsen`, `Move ${feature.title[1]} with the arrow keys`)}
                onpointerdown={(e) => grab(e, feature.id)} onpointermove={drag} onpointerup={drop} onpointercancel={drop} onkeydown={(e) => nudge(e, feature.id)}><Icon name="grip" size={16} /></button>
              <span class="glyph"><Icon name={feature.icon} size={16} /></span>
              <span class="what"><span>{tr(...feature.title)}</span><span class="faint">{tr(...feature.hint)}</span></span>
              <button class="ghost toggle on" onclick={() => remove(feature.id)} title={tr("Van Home halen", "Remove from Home")} aria-label={tr(`${feature.title[0]} van Home halen`, `Remove ${feature.title[1]} from Home`)}><Icon name="check" size={15} /></button>
            </li>
          {/each}
        </ul>
      {:else}
        <p class="faint none">{tr("Nog niets gekozen. Voeg hieronder toe wat je het meest gebruikt.", "Nothing chosen yet. Add what you use most below.")}</p>
      {/if}

      {#if others.length}
        <h4>{tr("Meer van Nook", "More from Nook")}</h4>
        <ul class="rows">
          {#each others as feature (feature.id)}
            <li class="row" animate:flip={{ duration: 200, easing: cubicOut }}>
              <span class="glyph dim"><Icon name={feature.icon} size={16} /></span>
              <span class="what"><span>{tr(...feature.title)}</span><span class="faint">{tr(...feature.hint)}</span></span>
              <button class="ghost toggle" onclick={() => add(feature.id)} title={tr("Op Home zetten", "Add to Home")} aria-label={tr(`${feature.title[0]} op Home zetten`, `Add ${feature.title[1]} to Home`)}><Icon name="plus" size={15} /></button>
            </li>
          {/each}
        </ul>
      {/if}
    </div>

    <footer><button class="primary" onclick={onclose}>{tr("Klaar", "Done")}</button></footer>
  </div>
</div>

<style>
  .backdrop { position: fixed; inset: 0; background: rgba(0, 0, 0, 0.55); display: grid; place-items: center; z-index: 50; padding: 16px; }
  .sheet { background: var(--graphite); border: 1px solid var(--line2); border-radius: var(--radius-panel); width: min(520px, 100%); max-height: 88vh; display: flex; flex-direction: column; overflow: hidden; box-shadow: var(--shadow-popover); }
  header { display: flex; gap: 14px; align-items: flex-start; padding: 20px 20px 6px; }
  header > div { flex: 1; min-width: 0; }
  header h3 { margin: 0; font-size: 16px; }
  header p { margin: 4px 0 0; font-size: 12px; }
  .close { width: 30px; height: 30px; padding: 0; display: grid; place-items: center; }
  .body { overflow-y: auto; padding: 8px 20px 12px; }
  .name { display: flex; flex-direction: column; gap: 6px; margin: 10px 0 6px; font-size: 12px; color: var(--text2); }
  h4 { margin: 20px 0 8px; font-size: 11px; font-weight: 650; letter-spacing: 1.2px; text-transform: uppercase; color: var(--text3); }
  .rows { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 2px; }
  .row { display: flex; align-items: center; gap: 10px; padding: 6px 6px 6px 4px; border-radius: var(--radius-control); background: transparent; transition: background 160ms ease, box-shadow 160ms ease; }
  .row:hover { background: var(--row-hover); }
  .row.dragging { background: var(--smoke); box-shadow: var(--shadow-popover); position: relative; z-index: 1; }
  .grip { width: 26px; height: 30px; padding: 0; display: grid; place-items: center; cursor: grab; color: var(--text3); touch-action: none; }
  .row.dragging .grip { cursor: grabbing; }
  .glyph { width: 30px; height: 30px; border-radius: 9px; display: grid; place-items: center; background: color-mix(in srgb, var(--paper) 7%, transparent); flex: none; }
  .glyph.dim { color: var(--text2); margin-left: 36px; }
  .what { flex: 1; min-width: 0; display: flex; flex-direction: column; }
  .what span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .what .faint { font-size: 11px; }
  .toggle { width: 30px; height: 30px; padding: 0; display: grid; place-items: center; border-radius: 999px; border: 1px solid var(--line2); }
  .toggle.on { color: var(--mint); border-color: color-mix(in srgb, var(--mint) 35%, transparent); background: color-mix(in srgb, var(--mint) 8%, transparent); }
  .none { margin: 4px 0; font-size: 12px; }
  footer { display: flex; justify-content: flex-end; padding: 12px 20px 18px; border-top: 1px solid var(--line); }
</style>
