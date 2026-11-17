<script lang="ts">
  // The pill and panel of the model picker (`ModelPickerDropdown`): the trigger the caller draws, and under it (or
  // above it near the bottom of the window) a panel of the picker's one width, wider with a column beside the models.
  // Escape, a click outside and a pick close it; Ctrl+Shift+M opens it, as ⇧⌘M does on the Mac.
  import type { Snippet } from "svelte";
  import { MODEL_PICKER } from "../../lib/model-picker";

  let { trigger, content, hasSideColumn = false, shortcut = true, open = $bindable(false) }: {
    /** The pill; `toggle` opens or closes the panel. */
    trigger: Snippet<[{ open: boolean; toggle: () => void }]>;
    /** The panel's content, usually a `ModelPicker`; `close` closes the panel. */
    content: Snippet<[() => void]>;
    /** A column beside the models (reasoning levels) makes the panel wider. */
    hasSideColumn?: boolean;
    /** Ctrl+Shift+M opens this picker; only the composer's own picker should take it. */
    shortcut?: boolean;
    open?: boolean;
  } = $props();

  let host = $state<HTMLDivElement>();
  let panel = $state<HTMLDivElement>();
  let above = $state(false);
  const width = $derived(MODEL_PICKER.width + (hasSideColumn ? MODEL_PICKER.sideWidth : 0));

  const close = () => (open = false);
  function toggle() {
    if (!open && host) above = host.getBoundingClientRect().bottom > window.innerHeight * 0.55;
    open = !open;
  }

  $effect(() => {
    const keys = (e: KeyboardEvent) => {
      if (open && e.key === "Escape") { e.stopPropagation(); close(); }
      else if (shortcut && e.ctrlKey && e.shiftKey && !e.altKey && e.key.toLowerCase() === "m") { e.preventDefault(); toggle(); }
    };
    const outside = (e: PointerEvent) => {
      if (open && host && !host.contains(e.target as Node)) close();
    };
    window.addEventListener("keydown", keys, true);
    window.addEventListener("pointerdown", outside, true);
    return () => {
      window.removeEventListener("keydown", keys, true);
      window.removeEventListener("pointerdown", outside, true);
    };
  });

  // Keep the panel inside the window: shift it left when it would run past the right edge.
  $effect(() => {
    if (!open || !panel) return;
    panel.style.left = "0px";
    const r = panel.getBoundingClientRect();
    const over = r.right - (window.innerWidth - 8);
    if (over > 0) panel.style.left = `${-over}px`;
  });
</script>

<div class="model-dropdown" bind:this={host}>
  {@render trigger({ open, toggle })}
  {#if open}
    <div class="panel" class:above bind:this={panel} style:width="{width}px">{@render content(close)}</div>
  {/if}
</div>

<style>
  .model-dropdown { position: relative; display: inline-flex; }
  .panel { position: absolute; z-index: 40; top: calc(100% + var(--space-6)); left: 0; overflow: hidden; background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-panel); box-shadow: var(--shadow-popover); }
  .panel.above { top: auto; bottom: calc(100% + var(--space-6)); }
</style>
