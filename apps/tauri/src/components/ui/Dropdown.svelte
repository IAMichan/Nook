<script lang="ts">
  // A composer choice that opens a panel of rows (the Mac's `ComposerDropdown`): the quiet pill as trigger, and instead of
  // a system menu a dark panel with a header, rows with an icon or logo, a title and a description, and a faint fill on
  // the chosen row. Opens above its pill (the composer sits at the bottom of the window); a click outside or Escape
  // closes it.
  import type { Snippet } from "svelte";

  let { width = 264, open = $bindable(false), trigger, children, label, align = "left", below = false, onopen }: {
    width?: number;
    open?: boolean;
    trigger: Snippet<[{ open: boolean; toggle: () => void }]>;
    children: Snippet<[{ close: () => void }]>;
    label?: string;
    align?: "left" | "right";
    /** Opens under its trigger instead of above it: for a header at the top of the window. */
    below?: boolean;
    onopen?: () => void;
  } = $props();

  let root = $state<HTMLDivElement>();
  const close = () => (open = false);
  function toggle() {
    open = !open;
    if (open) onopen?.();
  }

  $effect(() => {
    if (!open) return;
    const esc = (e: KeyboardEvent) => {
      if (e.key === "Escape") { e.stopPropagation(); e.preventDefault(); close(); }
    };
    const outside = (e: MouseEvent) => { if (!root?.contains(e.target as Node)) close(); };
    window.addEventListener("keydown", esc, true);
    window.addEventListener("mousedown", outside, true);
    return () => {
      window.removeEventListener("keydown", esc, true);
      window.removeEventListener("mousedown", outside, true);
    };
  });
</script>

<div class="dropdown" bind:this={root}>
  {@render trigger({ open, toggle })}
  {#if open}
    <div class="panel" class:right={align === "right"} class:below role="dialog" aria-label={label} style:width="{width}px">
      {@render children({ close })}
    </div>
  {/if}
</div>

<style>
  .dropdown { position: relative; display: inline-flex; min-width: 0; max-width: 100%; }
  /* The palette's `menu`: a panel lifts off the black canvas by a grey step and a line, as a popover does on the Mac. */
  .panel {
    position: absolute; bottom: calc(100% + var(--space-6)); left: 0; z-index: 40;
    display: flex; flex-direction: column; max-width: calc(100vw - 24px); max-height: min(560px, 70vh); overflow: hidden auto;
    padding: var(--space-4); background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-card);
    box-shadow: var(--shadow-popover); text-align: left;
  }
  .panel.right { left: auto; right: 0; }
  .panel.below { bottom: auto; top: calc(100% + var(--space-6)); }
  /* The header over a group of rows (`DropdownHeader`). */
  .panel :global(.dd-header) { padding: var(--space-8) var(--space-8) var(--space-4); font: var(--text-label); color: var(--text3); }
</style>
